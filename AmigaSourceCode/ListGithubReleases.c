/*
 * ListReleases.c - Native AmigaOS 3.x (m68k) GitHub Release Tool
 * 
 * Features:
 *   - True AmigaDOS Wildcard Pattern Matching (#?, ?, *, |, ~) via ParsePatternNoCase / MatchPatternNoCase
 *   - Memory-Safe, Low Stack Allocation (Crash-proof on real hardware)
 *   - Auto HTTP 301/302 Redirect Following (e.g. jens-maus/amissl -> AmiSSL/amissl)
 *   - Silent aget background fetching
 *   - Semantic Version Sorting (SORT=DESC, SORT=ASC, SORT=DATE, SORT=NAME)
 *
 * Target: Motorola 68000 - 68060 (AmigaOS 3.x)
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <dos/dos.h>
#include <dos/rdargs.h>
#include <dos/dostags.h>

#include <proto/exec.h>
#include <proto/dos.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static const char verstag[] = "$VER: ListReleases 2.14 (23.08.2026) (m68k AmigaOS 3.x)";

#define TEMPLATE "URL/A,PATTERN/K,EXT/K,LIMIT/N,FORMAT/K,SORT/K,TO/K,LINKS/S,SCRIPT/S,ALL/S,HELP/S"

enum {
    ARG_URL,
    ARG_PATTERN,
    ARG_EXT,
    ARG_LIMIT,
    ARG_FORMAT,
    ARG_SORT,
    ARG_TO,
    ARG_LINKS,
    ARG_SCRIPT,
    ARG_ALL,
    ARG_HELP,
    ARG_COUNT
};

struct ReleaseAsset {
    char *name;
    char *url;
    ULONG size;
    ULONG download_count;
};

struct GithubRelease {
    char *tag_name;
    char *name;
    char date[16];
    char raw_date[16];
    int is_draft;
    int is_prerelease;
    int asset_count;
    struct ReleaseAsset *assets;
};

static struct GithubRelease **g_releases = NULL;
static int g_release_count = 0;
static int g_release_capacity = 0;

/* AmigaDOS Parsed Pattern Buffer */
static char g_parsed_pattern[512] = {0};
static int  g_pattern_is_active = 0;
static char g_raw_pattern[256] = {0};

static const char *MONTHS[] = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
};

static void FormatAmigaDate(const char *isoDate, char *out, size_t out_len) {
    if (!isoDate || strlen(isoDate) < 10) {
        snprintf(out, out_len, "%s", isoDate ? isoDate : "N/A");
        return;
    }
    int year = 0, month = 0, day = 0;
    if (sscanf(isoDate, "%d-%d-%d", &year, &month, &day) == 3 && month >= 1 && month <= 12) {
        snprintf(out, out_len, "%02d-%s-%04d", day, MONTHS[month - 1], year);
    } else {
        snprintf(out, out_len, "%.10s", isoDate);
    }
}

static void FormatBytes(ULONG bytes, char *out, size_t out_len) {
    if (bytes < 1024) {
        snprintf(out, out_len, "%lu B", (unsigned long)bytes);
    } else if (bytes < 1024 * 1024) {
        snprintf(out, out_len, "%lu.%lu KB", (unsigned long)(bytes / 1024), (unsigned long)(((bytes % 1024) * 10) / 1024));
    } else {
        snprintf(out, out_len, "%lu.%lu MB", (unsigned long)(bytes / (1024 * 1024)), (unsigned long)(((bytes % (1024 * 1024)) * 10) / (1024 * 1024)));
    }
}

/* Initialize AmigaDOS pattern parsing for both #? and * wildcards */
static void SetupAmigaPattern(const char *pattern) {
    g_pattern_is_active = 0;
    if (!pattern || !*pattern || strcasecmp(pattern, "ALL") == 0 || strcmp(pattern, "#?") == 0 || strcmp(pattern, "*") == 0) {
        return;
    }

    strncpy(g_raw_pattern, pattern, sizeof(g_raw_pattern) - 1);
    g_raw_pattern[sizeof(g_raw_pattern) - 1] = '\0';

    /* Convert standard '*' wildcards to AmigaDOS '#?' wildcards */
    char amiPat[256];
    size_t j = 0;
    for (size_t i = 0; g_raw_pattern[i] && j < sizeof(amiPat) - 3; i++) {
        if (g_raw_pattern[i] == '*') {
            amiPat[j++] = '#';
            amiPat[j++] = '?';
        } else {
            amiPat[j++] = g_raw_pattern[i];
        }
    }
    amiPat[j] = '\0';

    /* Parse AmigaDOS pattern */
    LONG res = ParsePatternNoCase((CONST_STRPTR)amiPat, (STRPTR)g_parsed_pattern, sizeof(g_parsed_pattern));
    if (res >= 0) {
        g_pattern_is_active = 1;
    } else {
        /* Fallback without tokenization */
        g_pattern_is_active = 2;
    }
}

/* Match filename using native AmigaDOS MatchPatternNoCase */
static int MatchesAssetPattern(const char *assetName) {
    if (!g_pattern_is_active) {
        return 1;
    }
    if (!assetName) return 0;

    if (g_pattern_is_active == 1) {
        if (MatchPatternNoCase((CONST_STRPTR)g_parsed_pattern, (CONST_STRPTR)assetName)) {
            return 1;
        }
    }

    /* Fallback: case-insensitive substring search */
    const char *a = assetName;
    const char *p = g_raw_pattern;
    while (*a) {
        const char *h = a;
        const char *n = p;
        while (*h && *n && tolower((unsigned char)*h) == tolower((unsigned char)*n)) {
            h++;
            n++;
        }
        if (!*n) return 1;
        a++;
    }
    return 0;
}

static int MatchesExtension(const char *filename, const char *ext) {
    if (!ext || !*ext || strcasecmp(ext, "ALL") == 0) return 1;
    if (!filename) return 0;
    
    size_t flen = strlen(filename);
    size_t elen = strlen(ext);
    if (ext[0] == '.') { ext++; elen--; }
    if (elen == 0 || flen < elen) return 0;

    const char *dot = filename + flen - elen;
    if (dot > filename && *(dot - 1) == '.') {
        return strcasecmp(dot, ext) == 0;
    }
    return 0;
}

static int ParseGitHubUrl(const char *url, char *owner, char *repo, char *apiUrl, size_t apiMaxLen) {
    const char *p = url;
    char *out;

    if (!url || url[0] == '\0') return 0;

    if (strncasecmp(p, "https://", 8) == 0) p += 8;
    else if (strncasecmp(p, "http://", 7) == 0) p += 7;
    else return 0;

    if (strncasecmp(p, "www.", 4) == 0) p += 4;

    if (strncasecmp(p, "api.github.com/repos/", 21) == 0) {
        p += 21;
    } else if (strncasecmp(p, "github.com/", 11) == 0) {
        p += 11;
    } else {
        return 0;
    }

    out = owner;
    while (*p && *p != '/' && *p != '?' && *p != '#') *out++ = *p++;
    *out = '\0';
    if (*p != '/') return 0;
    p++;

    out = repo;
    while (*p && *p != '/' && *p != '?' && *p != '#') *out++ = *p++;
    *out = '\0';

    if (owner[0] == '\0' || repo[0] == '\0') return 0;

    size_t rlen = strlen(repo);
    if (rlen > 4 && strcasecmp(repo + rlen - 4, ".git") == 0) {
        repo[rlen - 4] = '\0';
    }

    snprintf(apiUrl, apiMaxLen, "https://api.github.com/repos/%s/%s/releases", owner, repo);
    return 1;
}

static int ParseSemVerParts(const char *v, long *parts, int maxParts) {
    int count = 0;
    const char *p = v;
    
    while (*p && !isdigit((unsigned char)*p)) p++;

    while (*p && count < maxParts) {
        if (isdigit((unsigned char)*p)) {
            parts[count++] = strtol(p, (char **)&p, 10);
        } else {
            p++;
        }
    }
    return count;
}

static int CompareSemVerM68k(const char *tagA, const char *tagB) {
    long partsA[8] = {0};
    long partsB[8] = {0};

    int countA = ParseSemVerParts(tagA, partsA, 8);
    int countB = ParseSemVerParts(tagB, partsB, 8);
    int maxCount = countA > countB ? countA : countB;

    for (int i = 0; i < maxCount; i++) {
        long a = (i < countA) ? partsA[i] : 0;
        long b = (i < countB) ? partsB[i] : 0;
        if (a != b) {
            return (a > b) ? 1 : -1;
        }
    }
    return strcasecmp(tagA ? tagA : "", tagB ? tagB : "");
}

static void SortReleasesArray(const char *sortMode) {
    if (!sortMode) sortMode = "DESC";

    for (int i = 0; i < g_release_count - 1; i++) {
        for (int j = i + 1; j < g_release_count; j++) {
            int swap = 0;
            if (strcasecmp(sortMode, "ASC") == 0 || strcasecmp(sortMode, "ASCENDING") == 0) {
                if (CompareSemVerM68k(g_releases[i]->tag_name, g_releases[j]->tag_name) > 0) {
                    swap = 1;
                }
            } else if (strcasecmp(sortMode, "DATE") == 0) {
                if (strcmp(g_releases[i]->raw_date, g_releases[j]->raw_date) < 0) {
                    swap = 1;
                }
            } else if (strcasecmp(sortMode, "NAME") == 0) {
                if (strcasecmp(g_releases[i]->name ? g_releases[i]->name : "",
                               g_releases[j]->name ? g_releases[j]->name : "") > 0) {
                    swap = 1;
                }
            } else {
                if (CompareSemVerM68k(g_releases[i]->tag_name, g_releases[j]->tag_name) < 0) {
                    swap = 1;
                }
            }

            if (swap) {
                struct GithubRelease *temp = g_releases[i];
                g_releases[i] = g_releases[j];
                g_releases[j] = temp;
            }
        }
    }
}

static char *SliceDupString(const char *start, const char *end, const char *key) {
    char search[64];
    snprintf(search, sizeof(search), "\"%s\":", key);
    const char *p = strstr(start, search);
    if (!p || p >= end) return NULL;
    p += strlen(search);
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (p >= end || *p != '"') return NULL;
    p++;

    const char *s_start = p;
    size_t len = 0;
    while (p < end && *p != '"') {
        if (*p == '\\' && (p + 1) < end) p++;
        p++;
        len++;
    }

    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;

    p = s_start;
    size_t i = 0;
    while (p < end && *p != '"') {
        if (*p == '\\' && (p + 1) < end) p++;
        out[i++] = *p++;
    }
    out[i] = '\0';
    return out;
}

static int SliceGetInt(const char *start, const char *end, const char *key, ULONG *out) {
    char search[64];
    snprintf(search, sizeof(search), "\"%s\":", key);
    const char *p = strstr(start, search);
    if (!p || p >= end) return 0;
    p += strlen(search);
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) p++;
    if (p >= end) return 0;
    *out = (ULONG)strtoul(p, NULL, 10);
    return 1;
}

static int SliceGetBool(const char *start, const char *end, const char *key) {
    char search[64];
    snprintf(search, sizeof(search), "\"%s\":", key);
    const char *p = strstr(start, search);
    if (!p || p >= end) return 0;
    p += strlen(search);
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    return (p + 4 <= end && strncasecmp(p, "true", 4) == 0);
}

static void FreeAllReleases(void) {
    if (!g_releases) return;
    for (int i = 0; i < g_release_count; i++) {
        struct GithubRelease *r = g_releases[i];
        if (r) {
            if (r->tag_name) free(r->tag_name);
            if (r->name) free(r->name);
            if (r->assets) {
                for (int j = 0; j < r->asset_count; j++) {
                    if (r->assets[j].name) free(r->assets[j].name);
                    if (r->assets[j].url) free(r->assets[j].url);
                }
                free(r->assets);
            }
            free(r);
        }
    }
    free(g_releases);
    g_releases = NULL;
    g_release_count = 0;
    g_release_capacity = 0;
}

static void ParseGitHubJson(const char *json) {
    FreeAllReleases();
    const char *p = json;

    while (*p && *p != '[') p++;
    if (!*p) return;
    p++;

    g_release_capacity = 32;
    g_releases = (struct GithubRelease **)malloc(sizeof(struct GithubRelease *) * g_release_capacity);
    if (!g_releases) return;

    while (*p && g_release_count < 100) {
        while (*p && *p != '{' && *p != ']') p++;
        if (!*p || *p == ']') break;

        const char *rel_start = p;
        int depth = 0;
        int in_str = 0;
        const char *rel_end = NULL;

        while (*p) {
            if (*p == '"' && (p == json || *(p - 1) != '\\')) {
                in_str = !in_str;
            } else if (!in_str) {
                if (*p == '{') depth++;
                else if (*p == '}') {
                    depth--;
                    if (depth == 0) {
                        rel_end = p + 1;
                        break;
                    }
                }
            }
            p++;
        }

        if (!rel_end) break;

        struct GithubRelease *rel = (struct GithubRelease *)calloc(1, sizeof(struct GithubRelease));
        if (!rel) break;

        rel->tag_name = SliceDupString(rel_start, rel_end, "tag_name");
        rel->name = SliceDupString(rel_start, rel_end, "name");
        
        char *rawDate = SliceDupString(rel_start, rel_end, "published_at");
        if (!rawDate) {
            rawDate = SliceDupString(rel_start, rel_end, "created_at");
        }
        if (rawDate) {
            snprintf(rel->raw_date, sizeof(rel->raw_date), "%.10s", rawDate);
            FormatAmigaDate(rawDate, rel->date, sizeof(rel->date));
            free(rawDate);
        } else {
            strcpy(rel->date, "N/A");
        }

        rel->is_draft = SliceGetBool(rel_start, rel_end, "draft");
        rel->is_prerelease = SliceGetBool(rel_start, rel_end, "prerelease");

        const char *assets_key = strstr(rel_start, "\"assets\":");
        if (assets_key && assets_key < rel_end) {
            const char *a_ptr = assets_key;
            while (a_ptr < rel_end && *a_ptr != '[') a_ptr++;
            if (a_ptr < rel_end && *a_ptr == '[') {
                a_ptr++;
                int asset_cap = 8;
                rel->assets = (struct ReleaseAsset *)calloc(asset_cap, sizeof(struct ReleaseAsset));

                while (a_ptr < rel_end && rel->asset_count < 64) {
                    while (a_ptr < rel_end && *a_ptr != '{' && *a_ptr != ']') a_ptr++;
                    if (a_ptr >= rel_end || *a_ptr == ']') break;

                    const char *asset_start = a_ptr;
                    int a_depth = 0;
                    int a_in_str = 0;
                    const char *asset_end = NULL;

                    while (a_ptr < rel_end) {
                        if (*a_ptr == '"' && *(a_ptr - 1) != '\\') {
                            a_in_str = !a_in_str;
                        } else if (!a_in_str) {
                            if (*a_ptr == '{') a_depth++;
                            else if (*a_ptr == '}') {
                                a_depth--;
                                if (a_depth == 0) {
                                    asset_end = a_ptr + 1;
                                    break;
                                }
                            }
                        }
                        a_ptr++;
                    }

                    if (!asset_end) break;

                    if (rel->asset_count >= asset_cap) {
                        asset_cap *= 2;
                        rel->assets = (struct ReleaseAsset *)realloc(rel->assets, sizeof(struct ReleaseAsset) * asset_cap);
                    }

                    struct ReleaseAsset *asset = &rel->assets[rel->asset_count];
                    asset->name = SliceDupString(asset_start, asset_end, "name");
                    asset->url = SliceDupString(asset_start, asset_end, "browser_download_url");
                    SliceGetInt(asset_start, asset_end, "size", &asset->size);
                    SliceGetInt(asset_start, asset_end, "download_count", &asset->download_count);

                    if (asset->name != NULL) {
                        rel->asset_count++;
                    }
                }
            }
        }

        if (rel->tag_name != NULL) {
            if (g_release_count >= g_release_capacity) {
                g_release_capacity *= 2;
                g_releases = (struct GithubRelease **)realloc(g_releases, sizeof(struct GithubRelease *) * g_release_capacity);
            }
            g_releases[g_release_count++] = rel;
        } else {
            free(rel);
        }
        p = rel_end;
    }
}

static void GenerateDownloadScript(const char *repo, const char *outfile, const char *ext) {
    FILE *f = outfile ? fopen(outfile, "w") : stdout;
    if (!f) {
        printf("Error: Could not open output file '%s' for writing.\n", outfile);
        return;
    }

    fprintf(f, "; AmigaDOS Release Download Script (using aget)\n");
    fprintf(f, "; Generated for repository: %s\n\n", repo);
    fprintf(f, "FailAt 21\n");
    fprintf(f, "MakeDir RAM:Downloads\n\n");

    int count = 0;
    for (int i = 0; i < g_release_count; i++) {
        struct GithubRelease *r = g_releases[i];
        for (int j = 0; j < r->asset_count; j++) {
            struct ReleaseAsset *a = &r->assets[j];
            if (!MatchesAssetPattern(a->name)) continue;
            if (ext && !MatchesExtension(a->name, ext)) continue;

            fprintf(f, "Echo \"Downloading %s (%s)...\"\n", a->name, r->tag_name);
            fprintf(f, "aget \"%s\" TO \"RAM:Downloads/%s\" >NIL:\n", a->url, a->name);
            fprintf(f, "If WARN\n  Echo \"Failed to download %s\"\nEndIf\n\n", a->name);
            count++;
        }
    }
    fprintf(f, "Echo \"Done! Processed %d asset(s) to RAM:Downloads/\"\n", count);

    if (outfile) {
        fclose(f);
        printf("Saved AmigaDOS download script to: %s (%d files)\n", outfile, count);
        printf("To execute, type: Execute %s\n", outfile);
    }
}

static void ShowHelp(void) {
    printf("ListReleases 2.14 (m68k AmigaOS 3.x - Wildcards)\n");
    printf("Template: %s\n\n", TEMPLATE);
    printf("Arguments:\n");
    printf("  URL/A       : Full GitHub API or Web URL (REQUIRED)\n");
    printf("  PATTERN/K   : Pattern with #? or * wildcards (e.g. PATTERN=\"AmiSSL-#?-OS3#?\")\n");
    printf("  EXT/K       : File extension filter on asset (e.g. EXT=zip, EXT=lha)\n");
    printf("  LIMIT/N     : Max releases to list\n");
    printf("  FORMAT/K    : Output format (TABLE, LIST, URLS, SCRIPT)\n");
    printf("  SORT/K      : Sorting order: DESC (SemVer Descending, default), ASC, DATE, NAME\n");
    printf("  TO/K        : Output script to file (e.g. TO=RAM:get_files.cmd)\n");
    printf("  LINKS/S     : Print full direct asset download URLs\n");
    printf("  SCRIPT/S    : Generate AmigaDOS download script\n");
    printf("  ALL/S       : Include pre-releases and draft versions\n");
    printf("  HELP/S or ? : Display this help screen\n\n");
}

static LONG ExecuteQuiet(const char *cmd) {
    BPTR nilHandle = Open((CONST_STRPTR)"NIL:", MODE_NEWFILE);
    struct TagItem tags[] = {
        { SYS_Output, (ULONG)nilHandle },
        { SYS_Input,  (ULONG)NULL },
        { TAG_DONE, 0 }
    };
    LONG res = SystemTagList((CONST_STRPTR)cmd, nilHandle ? tags : NULL);
    if (nilHandle) {
        Close(nilHandle);
    }
    return res;
}

static char *FetchUrlData(const char *targetUrl, long *outSize) {
    DeleteFile((CONST_STRPTR)"T:releases.json");

    char fetchCmd[1024];
    snprintf(fetchCmd, sizeof(fetchCmd), "aget \"%s\" TO \"T:releases.json\" QUIET", targetUrl);
    ExecuteQuiet(fetchCmd);

    FILE *f = fopen("T:releases.json", "rb");
    if (!f) {
        snprintf(fetchCmd, sizeof(fetchCmd), "aget \"%s\" TO \"T:releases.json\"", targetUrl);
        ExecuteQuiet(fetchCmd);
        f = fopen("T:releases.json", "rb");
    }

    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (fsize <= 10) {
        fclose(f);
        DeleteFile((CONST_STRPTR)"T:releases.json");
        return NULL;
    }

    char *buf = (char *)malloc(fsize + 1);
    if (!buf) {
        fclose(f);
        DeleteFile((CONST_STRPTR)"T:releases.json");
        return NULL;
    }

    fread(buf, 1, fsize, f);
    buf[fsize] = '\0';
    fclose(f);
    DeleteFile((CONST_STRPTR)"T:releases.json");

    *outSize = fsize;
    return buf;
}

int main(int argc, char **argv) {
    struct RDArgs *rdargs;
    LONG args[ARG_COUNT];
    char owner[128], repo[128], apiUrl[512];

    (void)verstag;
    memset(args, 0, sizeof(args));

    rdargs = ReadArgs((CONST_STRPTR)TEMPLATE, args, NULL);
    if (!rdargs) {
        PrintFault(IoErr(), (CONST_STRPTR)"ListReleases");
        return RETURN_ERROR;
    }

    if (args[ARG_HELP]) {
        ShowHelp();
        FreeArgs(rdargs);
        return RETURN_OK;
    }

    const char *url = (const char *)args[ARG_URL];
    if (!url || !ParseGitHubUrl(url, owner, repo, apiUrl, sizeof(apiUrl))) {
        fprintf(stderr, "*** AmigaDOS Error (IoErr 205): Invalid repository URL '%s'\n", url ? url : "");
        fprintf(stderr, "The repo argument must be a full GitHub API or Web URL.\n");
        FreeArgs(rdargs);
        return RETURN_ERROR;
    }

    const char *format  = args[ARG_FORMAT] ? (const char *)args[ARG_FORMAT] : "LIST";
    const char *sortOpt = args[ARG_SORT]   ? (const char *)args[ARG_SORT]   : "DESC";
    const char *ext     = args[ARG_EXT]    ? (const char *)args[ARG_EXT]    : NULL;
    const char *pat     = args[ARG_PATTERN]? (const char *)args[ARG_PATTERN]: NULL;
    const char *toFile  = args[ARG_TO]     ? (const char *)args[ARG_TO]     : NULL;
    LONG limit          = args[ARG_LIMIT]  ? *(LONG *)args[ARG_LIMIT]       : 0;
    int showLinks       = args[ARG_LINKS]  ? 1 : 0;
    int genScript       = args[ARG_SCRIPT] || (strcasecmp(format, "SCRIPT") == 0);
    int isTable         = (strcasecmp(format, "TABLE") == 0);
    int isUrls          = (strcasecmp(format, "URLS") == 0);
    int includeAll      = args[ARG_ALL] ? 1 : 0;

    /* Initialize AmigaDOS Pattern Matching */
    SetupAmigaPattern(pat);

    printf("Fetching releases from GitHub for '%s/%s'...\n", owner, repo);

    long fsize = 0;
    char *jsonBuf = FetchUrlData(apiUrl, &fsize);

    if (jsonBuf && strstr(jsonBuf, "\"message\": \"Moved Permanently\"")) {
        char *redirectUrl = SliceDupString(jsonBuf, jsonBuf + fsize, "url");
        if (redirectUrl) {
            printf("Following GitHub redirect: %s\n", redirectUrl);
            free(jsonBuf);
            jsonBuf = FetchUrlData(redirectUrl, &fsize);
            free(redirectUrl);
        }
    }

    if (!jsonBuf) {
        fprintf(stderr, "*** Error: Could not retrieve releases for '%s/%s'.\n", owner, repo);
        FreeArgs(rdargs);
        return RETURN_ERROR;
    }

    if (strstr(jsonBuf, "\"message\": \"Not Found\"")) {
        fprintf(stderr, "*** Error: Repository '%s/%s' not found or has no releases.\n", owner, repo);
        free(jsonBuf);
        FreeArgs(rdargs);
        return RETURN_ERROR;
    }
    if (strstr(jsonBuf, "API rate limit exceeded")) {
        fprintf(stderr, "*** Error: GitHub API rate limit exceeded. Please try again later.\n");
        free(jsonBuf);
        FreeArgs(rdargs);
        return RETURN_ERROR;
    }

    ParseGitHubJson(jsonBuf);
    free(jsonBuf);

    if (g_release_count == 0) {
        printf("No releases found for %s/%s\n", owner, repo);
        FreeAllReleases();
        FreeArgs(rdargs);
        return RETURN_OK;
    }

    SortReleasesArray(sortOpt);

    int displayed_releases = 0;
    int displayed_assets = 0;

    if (genScript) {
        GenerateDownloadScript(repo, toFile, ext);
        FreeAllReleases();
        FreeArgs(rdargs);
        return RETURN_OK;
    }

    if (isUrls) {
        for (int i = 0; i < g_release_count; i++) {
            if (limit > 0 && displayed_releases >= limit) break;
            struct GithubRelease *r = g_releases[i];
            if (!includeAll && (r->is_draft || r->is_prerelease)) continue;

            int relAssetMatched = 0;
            for (int j = 0; j < r->asset_count; j++) {
                struct ReleaseAsset *a = &r->assets[j];
                if (!MatchesAssetPattern(a->name)) continue;
                if (ext && !MatchesExtension(a->name, ext)) continue;
                printf("%s\n", a->url);
                displayed_assets++;
                relAssetMatched++;
            }
            if (relAssetMatched > 0) {
                displayed_releases++;
            }
        }
        FreeAllReleases();
        FreeArgs(rdargs);
        return RETURN_OK;
    }

    if (isTable) {
        printf("\nREPOSITORY RELEASES TABLE: %s/%s\n", owner, repo);
        if (showLinks) {
            printf("+---------------------+-------------+----------+--------------------------------------+-----------+--------+----------------------------------------------------------------------------------------------------------------------------+\n");
            printf("| TAG / VERSION       | DATE        | STATUS   | ASSET FILE NAME                      |      SIZE |    DLS | DOWNLOAD LINK                                                                                                              |\n");
            printf("+=====================+=============+==========+======================================+===========+========+============================================================================================================================+\n");
        } else {
            printf("+---------------------+-------------+----------+--------------------------------------+-----------+--------+\n");
            printf("| TAG / VERSION       | DATE        | STATUS   | ASSET FILE NAME                      |      SIZE |    DLS |\n");
            printf("+=====================+=============+==========+======================================+===========+========+\n");
        }

        for (int i = 0; i < g_release_count; i++) {
            if (limit > 0 && displayed_releases >= limit) break;
            struct GithubRelease *r = g_releases[i];
            if (!includeAll && (r->is_draft || r->is_prerelease)) continue;

            const char *status = r->is_draft ? "DRAFT" : (r->is_prerelease ? "PRE-REL" : "RELEASE");
            
            if (r->asset_count == 0) {
                if (!MatchesAssetPattern("(source code)")) continue;
                if (ext && !MatchesExtension("(source code)", ext)) continue;

                if (showLinks) {
                    printf("| %-19.19s | %-11.11s | %-8.8s | %-36.36s | %9.9s | %6s | %-122.122s |\n",
                           r->tag_name ? r->tag_name : "", r->date, status, "(source code)", "N/A", "-", "N/A");
                } else {
                    printf("| %-19.19s | %-11.11s | %-8.8s | %-36.36s | %9.9s | %6s |\n",
                           r->tag_name ? r->tag_name : "", r->date, status, "(source code)", "N/A", "-");
                }
                displayed_releases++;
            } else {
                int matchedInRel = 0;
                for (int j = 0; j < r->asset_count; j++) {
                    struct ReleaseAsset *a = &r->assets[j];
                    if (!MatchesAssetPattern(a->name)) continue;
                    if (ext && !MatchesExtension(a->name, ext)) continue;
                    char sizeStr[16];
                    FormatBytes(a->size, sizeStr, sizeof(sizeStr));

                    if (showLinks) {
                        printf("| %-19.19s | %-11.11s | %-8.8s | %-36.36s | %9.9s | %6lu | %-122.122s |\n",
                               (matchedInRel == 0 ? (r->tag_name ? r->tag_name : "") : ""),
                               (matchedInRel == 0 ? r->date : ""),
                               (matchedInRel == 0 ? status : ""),
                               a->name, sizeStr, (unsigned long)a->download_count, a->url ? a->url : "N/A");
                    } else {
                        printf("| %-19.19s | %-11.11s | %-8.8s | %-36.36s | %9.9s | %6lu |\n",
                               (matchedInRel == 0 ? (r->tag_name ? r->tag_name : "") : ""),
                               (matchedInRel == 0 ? r->date : ""),
                               (matchedInRel == 0 ? status : ""),
                               a->name, sizeStr, (unsigned long)a->download_count);
                    }
                    displayed_assets++;
                    matchedInRel++;
                }
                if (matchedInRel > 0) {
                    displayed_releases++;
                }
            }
        }

        if (showLinks) {
            printf("+---------------------+-------------+----------+--------------------------------------+-----------+--------+----------------------------------------------------------------------------------------------------------------------------+\n");
        } else {
            printf("+---------------------+-------------+----------+--------------------------------------+-----------+--------+\n");
        }
        printf("Summary: %d release(s) listed | %d downloadable asset(s)\n\n", displayed_releases, displayed_assets);
    } else {
        printf("\nReleases for repository: %s/%s\n", owner, repo);
        printf("================================================================================\n");

        for (int i = 0; i < g_release_count; i++) {
            if (limit > 0 && displayed_releases >= limit) break;
            struct GithubRelease *r = g_releases[i];
            if (!includeAll && (r->is_draft || r->is_prerelease)) continue;

            int matchedInRel = 0;
            for (int j = 0; j < r->asset_count; j++) {
                struct ReleaseAsset *a = &r->assets[j];
                if (!MatchesAssetPattern(a->name)) continue;
                if (ext && !MatchesExtension(a->name, ext)) continue;

                if (matchedInRel == 0) {
                    printf("[%d] TAG: %-16s DATE: %-12s %s%s\n",
                           displayed_releases + 1, r->tag_name ? r->tag_name : "", r->date,
                           r->is_prerelease ? "[PRERELEASE] " : "",
                           r->is_draft ? "[DRAFT]" : "");
                    if (r->name && r->tag_name && strcmp(r->name, r->tag_name) != 0) {
                        printf("    TITLE: %s\n", r->name);
                    }
                }

                char sizeStr[16];
                FormatBytes(a->size, sizeStr, sizeof(sizeStr));
                printf("      (%d) %-36.36s %10s  [%lu dls]\n", matchedInRel + 1, a->name, sizeStr, (unsigned long)a->download_count);
                if (showLinks) {
                    printf("          URL: %s\n", a->url ? a->url : "");
                }
                displayed_assets++;
                matchedInRel++;
            }
            if (matchedInRel > 0) {
                printf("--------------------------------------------------------------------------------\n");
                displayed_releases++;
            }
        }
        printf("Total: %d release(s) listed | %d asset(s)\n\n", displayed_releases, displayed_assets);
    }

    FreeAllReleases();
    FreeArgs(rdargs);
    return RETURN_OK;
}
