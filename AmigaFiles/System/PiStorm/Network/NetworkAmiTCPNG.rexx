/* $VER: NetworkRoadshow.rexx 1.0.1 (2026-06-30)                                      */
/* Script to take Amiga online and offline including sync of clock            */
/*                                                                            */

/******************************************************************************
 *                                                                            *
 * REQUIREMENTS:                                                              *
 * - IP Stack:            Roadshow                                   *
 * - Devices:             genet.device or wifipi.device or                    *
 *                        uaenet.device(for UAE, built-in)                    *
 *                        or v2expeth.device (Apollo V2)                      *
 * - Libraries:           rexxtricks.library                                  *
 * - Tools (in C:):       SetDST, WirelessManager, WaitUntilConnected, sntp,  *
 *                        mecho,KillDev,ListDevices, areweonline,             *
 *                        ApolloControl (Apollo only)                         *
 * - Script (in S:):      ProgressBar                                         *
 *                                                                            *
 *****************************************************************************/

OPTIONS RESULTS

if ~SHOW('L','rexxtricks.library') then addlib('rexxtricks.library',0,-30,0) 

PARSE ARG input 
input = upper(TRANSLATE(input, ' ', '='))
PARSE VAR input . 'ACTION' action .
PARSE VAR input . 'DEVICE' device .

device  = STRIP(device)
action  = STRIP(action)

SwitchWaitatEnd = "FALSE"
IF POS('WAITATEND', input) > 0 THEN SwitchWaitatEnd = "TRUE"

SwitchSilentRunning = "FALSE"
IF POS('SILENTRUNNING', input) > 0 THEN SwitchSilentRunning = "TRUE"

IF action = "CONNECT" & device = "" THEN SIGNAL ShowUsage

IF FIND("CONNECT DISCONNECT",action) = 0 THEN DO
   SAY "Error: Invalid ACTION '"action"'. Must be Connect or Disconnect."
   CALL CloseWindowMessage()
   EXIT 10
END

If SwitchSilentRunning = "FALSE" then DO
   SAY ""
   SAY "**********************************************"
   SAY "Running Network script for action: "action
   SAY "**********************************************"
END

SwitchKeepEnvStatus = "FALSE"
SwitchNoCloseWirelessManager = "FALSE"
SwitchNoSyncTime = "FALSE"

IF POS('NOCLOSEWIRELESSMANAGER', input) > 0 THEN SwitchNoCloseWirelessManager = "TRUE"
IF POS('NOSYNCTIME', input) > 0 THEN SwitchNoSyncTime = "TRUE"
IF POS('KEEPENVSTATUS', input) > 0 THEN SwitchKeepEnvStatus = "TRUE"

IF device ~= "" & ~POS(".", device) > 0 THEN device = device || ".DEVICE"

IF action = "CONNECT" then DO
   DevicebaseName = left(device,(LENGTH(device) - 7))
   IF FIND("WIFIPI GENET UAENET V2EXPETH",DevicebaseName) = 0 THEN DO
      SAY "Error: Unsupported DEVICE '"DevicebaseName"'. Supported: wifipi.device, genet.device, uaenet.device, v2expeth.device"
      CALL CloseWindowMessage()
      EXIT 10
   END
END

DEBUG = "FALSE"
IF POS('DEBUG', input) > 0 THEN DEBUG = "TRUE"

ADDRESS COMMAND

WirelessprefsPath = "SYS:Prefs/Env-Archive/sys/wireless.prefs"
WifiPiDevicePath   = "Sys:Devs/Networks/wifipi.device"
WirelesslogFilePath   = "RAM:wirelessmanagerlog.txt"
sntpLog = "RAM:sntplog.txt"
RoadshowParametersFile = "Sys:Pistorm/RoadshowParameters"

IF DEBUG = "TRUE" then DO
   SAY "Debug mode on"
   SAY "Action: "action
   SAY "Device: "device
   SAY "DevicebaseName: "DevicebaseName
   SAY "SwitchNoSyncTime: "SwitchNoSyncTime 
   SAY "SwitchNoCloseWirelessManager: "SwitchNoCloseWirelessManager
   SAY "SwitchWaitatEnd: "SwitchWaitatEnd
   SAY "SwitchKeepEnvStatus "SwitchKeepEnvStatus
   SAY "SwitchSilentRunning "SwitchSilentRunning 
   SAY "WirelessprefsPath: "WirelessprefsPath
   SAY "WifiPiDevicePath: "WifiPiDevicePath
   SAY "WirelesslogFilePath: "WirelesslogFilePath
   SAY "sntpLog: "sntplog
   SAY "RoadshowParametersFile: "RoadshowParametersFile
END

IF action = "CONNECT" then DO
   'areweonline'
   If RC = 0 then DO 
	   SAY ""
		SAY "You are already online! Disconnect first."
		CALL CloseWindowMessage()
      EXIT 10
   END
   
   IF device = "WIFIPI.DEVICE" THEN DO
      If SwitchSilentRunning = "FALSE" then DO
         SAY ""
         SAY "Connecting to Wifi Network"
      END
      If upper(RPIVersion()) = "UNKNOWN" then DO
         SAY ""
         Say "Wifipi.device only works on Pistorm! Aborting!"
         CALL CloseWindowMessage()
         EXIT 10
      END
      IF ~EXISTS(WirelessprefsPath) THEN DO
         SAY ""
         SAY "Cannot connect to Wifi! No Wireless.prefs file found!"
         SAY "You need to create a wireless.prefs file at ""SYS:Prefs/Env-Archive/sys"""
         CALL CloseWindowMessage()
         EXIT 10
      END
      IF OPEN('f',WirelessprefsPath,'R') then DO
		   vSSID = ""
			Do until EOF('f')
			   If vSSID ~= "" then LEAVE
            LineRead = Upper(STRIP(READLN('f')))
            IF POS('SSID=',LineRead) > 0 THEN DO
               parse var LineRead v1'SSID="'vSSID'"'
		      END
			END
		END
      if vSSID="" then DO
         SAY "No SSID found in ""SYS:Prefs/Env-Archive/sys/wireless.prefs""! You need to configure!"
         CALL CloseWindowMessage()
         EXIT 10
		END
		IF DEBUG="TRUE" then SAY "SSID found was: "vSSID   
      If ~KillWirelessManager() then DO
         CALL CloseWindowMessage()
         EXIT 10
      END  
      If SwitchSilentRunning = "FALSE" then DO
         SAY ""
         SAY "Connecting to Wireless. This may take a few moments......."
         SAY ""
         'setenv InProgressBar Connecting to Wireless'
         'run >T:Progressbar.txt rx S:ProgressBar.rexx'
      END
      'Run >NIL: C:wirelessmanager device='WifiPiDevicePath' CONFIG='WirelessprefsPath' VERBOSE >'WirelesslogFilePath
      'C:WaitUntilConnected device='WifiPiDevicePath' Unit=0 delay=100'
      If RC = 0 then DO
         If SwitchSilentRunning = "FALSE" then DO 
            'setenv InProgressBar COMPLETE'
            'delete T:Progressbar.txt >NIL: QUIET'
            'wait 1'
         END
      END
      ELSE DO
         If SwitchSilentRunning = "FALSE" then DO 
            'setenv InProgressBar ERROR'
            'delete T:Progressbar.txt >NIL: QUIET'
         END
         SAY ""
         SAY "Could not connect to Wifi!"
         If ~KillWirelessManager() then DO
            CALL CloseWindowMessage()
            EXIT 10
         END         
         EXIT 10
      END
   END
	
   IF device = "GENET.DEVICE" THEN DO
      If SwitchSilentRunning = "FALSE" then DO 
         SAY ""
         SAY "Connecting to Ethernet"
      END
      If RPIVersion() ~= "RPi4" then DO
         SAY ""
         Say "Genet.device only works on Pistorm with Raspberry Pi4 or CM4! Aborting!"
         CALL CloseWindowMessage()
         EXIT 10
      END
      If ~KillWirelessManager() then DO
         CALL CloseWindowMessage()
         EXIT 10
      END   
   END
	
   IF device = "UAENET.DEVICE" THEN DO
      If SwitchSilentRunning = "FALSE" then DO 
         SAY ""
         SAY "Connecting to Network in UAE (uaenet.device)"
      END
      if ~IsUAE() THEN DO
         CALL CloseWindowMessage()
         EXIT 10
      END
   END
   IF device = "V2EXPETH.DEVICE" THEN DO
      If SwitchSilentRunning = "FALSE" then DO
         SAY ""
         SAY "Connecting to Ethernet (v2expeth.device)"
      END
      if ~IsV2() THEN DO
         CALL CloseWindowMessage()
         EXIT 10
      END
   END

   CALL LoadRoadshowParams(DevicebaseName)
   If SwitchSilentRunning = "FALSE" then DO
      'setenv InProgressBar Connecting to Network'
      'run >T:Progressbar.txt rx S:ProgressBar.rexx'
   END
   'AddNetInterface 'DevicebaseName' TIMEOUT=50 >T:AddInterface.txt'
   'Search T:AddInterface.txt "Could not add" >NIL:'
   IF RC = 0 THEN DO
      If SwitchSilentRunning = "FALSE" then DO
         'setenv InProgressBar ERROR'
         'delete T:Progressbar.txt >NIL: QUIET'
      END
      SAY ""
      SAY "Error connecting to Roadshow"

      If ~KillWirelessManager() then DO
         CALL CloseWindowMessage()
         EXIT 10
      END         
      EXIT 10
   END
   ELSE DO
      If SwitchSilentRunning = "FALSE" then DO
         'setenv InProgressBar COMPLETE'
         'delete T:Progressbar.txt >NIL: QUIET'
         'wait 1'
      END
   END

   if SwitchNoSyncTime = "FALSE" then DO
      if SwitchSilentRunning = "FALSE" then SAY "Updating system time"
      If ~SyncTime() THEN DO
         CALL CloseWindowMessage()
         EXIT 5
      End
      ELSE DO
         TZONE = GETENV(TZONE) 
         if TZONE="" THEN DO
            TimeZoneOverride = GETENV(TZONEOVERRIDE)
            if TimeZoneOverride~="" then DO
               say TimeZoneOverride 
               say "Using Timezone override"
               'C:SetDST ZONE='vTimeZoneOverride' NOASK NOREQ QUIET >NIL:'
            END
            ELSE 'C:SetDST NOASK NOREQ QUIET >NIL:'
            /*
				If ~SyncTime() THEN DO
               CALL CloseWindowMessage()
               EXIT 5
            End
				*/
         END         
      END 
      if SwitchSilentRunning = "FALSE" then SAY "Time set and DST applied if applicable"
   END
   if RIGHT(upper(device), 7) = ".DEVICE" then DevicetoReport = LEFT(device, LENGTH(device) - 7) 
   ELSE DevicetoReport = device
   'setenv ConnectionType 'DevicetoReport   
   IF SwitchSilentRunning = "FALSE" THEN DO
      SAY ""
      say "Successfully connected to Network!" 
      SAY ""
     'shownetstatus'
   END
END

IF action = "DISCONNECT" then DO
  If SwitchKeepEnvStatus="FALSE" then DO
     'unsetenv ConnectionType'   
   END
   if SwitchSilentRunning = "FALSE" then DO
      SAY ""
      Say "Disconnecting Network"
      SAY ""
      SAY "Killing network shares"
   END
   CALL KillNetworkShares()
   CALL KillRoadshow()
   IF SwitchNoCloseWirelessManager = "FALSE" THEN DO
      If ~KillWirelessManager() then DO
         CALL CloseWindowMessage()
         EXIT 10
      END
   END

END

Call CloseWindowMessage()

EXIT 0

/* ================= FUNCTIONS ================= */

SyncTime:
 'c:sntp pool.ntp.org >'sntpLog
 'Search' sntpLog '"Unknown host" >NIL:'
 IF RC = 0 THEN DO
    SAY "Unable to synchronise time"
    'Delete' sntpLog 'QUIET'
    RETURN 0
 END
 ELSE RETURN 1
IsV2:
   'apollocontrol de'
   If RC >0 THEN DO
      If debug = "TRUE" THEN SAY "Apollo Accelerator not detected"
      RETURN 1
   END
   ELSE DO
      'apollocontrol se'
      ApolloType = GETENV(vBoardName)
      if left(ApolloType,2) = "V2" then do
         If debug = "TRUE" THEN SAY "Apollo V2 Card detected"
         RETURN 1   
      END
      ELSE DO
         If debug = "TRUE" THEN SAY "Apollo Accelerator is not V2"
         RETURN 0
      END  
   END    
IsUAE:
   'VERSION uaehf.device >NIL:'
   If RC >0 THEN DO
      If debug = "TRUE" THEN SAY "UAE not detected"
      RETURN 0
   END
   ELSE DO
      If debug = "TRUE" THEN SAY "UAE detected"
      RETURN 1
   END
KillRoadshow:
   'c:Netshutdown >NIL:'
   Return
  
KillNetworkShares:
   'c:ListDevices NOFORMATTABLE >T:NetworkShares.txt'
   IF OPEN('f','T:NetworkShares.txt','R') then DO
      DO while ~EOF('f')  
         Line = STRIP(READLN('f'))
         If line = "" then iterate
         parse var Line vDevice';'vRawDosType';'vDosType';'vDeviceName';'vUnit';'vVolume
			if (upper(vDeviceName))="L:SMB-HANDLER" | (upper(vDeviceName))="L:SMB2-HANDLER" THEN DO
            IF DEBUG="TRUE" then say "Running command: "vCmd
            vCmd = 'c:killdev 'vDevice
            vCmd
			END
      END
   END
   call close('f')
   'delete T:NetworkShares.txt QUIET >NIL:'
   RETURN   
KillWirelessManager:
   'Status COM=c:wirelessmanager >ENV:WirelessManagerPID'
   ProcessNumber = GETENV(WirelessManagerPID)
   IF ProcessNumber ~= "" THEN DO
      IF SwitchSilentRunning = "FALSE" then DO
         SAY ""
         Say "Quitting Wireless Manager"
      END
      'break 'ProcessNumber
   END 
   ELSE DO 
	   IF DEBUG="TRUE" then DO
         SAY ""
         SAY "Wireless Manager not already running"   
     END
	END

  Outcome = UNSETENV(WirelessManagerPID)

  RETURN 1

RpiVersion:
   RpiType = GETENV(rpitype)
   if RpiType~="" THEN RETURN RpiType
   'VERSION brcm-emmc.device >nil:'
   if RC=0 then RETURN 'RPi4'
   'version brcm-sdhc.device >NIL:'
   if RC=0 then RETURN 'RPi3'
   Return "Unknown"
LoadRoadshowParams:
   PARSE ARG targetDevice
   if ~READFILE(RoadshowParametersFile,ReadLines) then RETURN
   do i=1 to Readlines.0
   IF Readlines.i = "" | LEFT(Readlines.i, 1) = ";" THEN iterate
     parse var Readlines.i vType';'vParameter';'vValue
     if upper(vType) ~= targetDevice then iterate
     SELECT
        WHEN upper(vParameter) = "TCPRECEIVE" THEN vCmd = 'roadshowcontrol tcp.recvspace='vValue' >NIL:'
        WHEN upper(vParameter)= "UDPRECEIVE" THEN vCmd = 'roadshowcontrol udp.recvspace='vValue' >NIL:'
        WHEN upper(vParameter) = "TCPSEND" THEN vCmd = 'roadshowcontrol tcp.sendspace='vValue' >NIL:'
        WHEN upper(vParameter) = "UDPSEND" THEN vCmd = 'roadshowcontrol udp.sendspace='vValue' >NIL:'
        OTHERWISE nop
     end
     if DEBUG="TRUE" then SAY vCmd
     vCmd
   end
   RETURN
CloseWindowMessage:
   If SwitchWaitatEnd="TRUE" then DO
      SAY ""
      say "Window will close in 3 seconds"
      ADDRESS COMMAND
      'wait sec=3'
      EXIT
   END
   Return

ShowUsage:
   SAY ""
   SAY "Arexx program to connect to network using Roadshow and to synchronise time"
   SAY ""
   SAY "Usage: Rx Network.rexx ACTION=<Action Type> DEVICE=<Selected Device> <Options>"
   SAY "<Action Type>: Connect, Disconnect"
   SAY "<Selected Device>: WifiPi, Genet, Uaenet, V2expeth (applicable for Connect action type)"
   SAY "<Options>: NoSyncTime, NoRestartWirelessManager (applicable for connect action type)"
   SAY "<Options>: NoCloseWirelessManager, NoCloseMiami (applicable for disconnect action type)"
   SAY "<Options>: Debug, WaitatEnd"
   SAY ""
   SAY "Example Usage:"
   SAY "Connect to wifipi.device"
   SAY "Rx Network.rexx ACTION=Connect DEVICE=wifipi"
   SAY ""
   SAY "Disconnect from network"
   SAY "Rx Network.rexx ACTION=Disconnect" 
   SAY ""
   CALL CloseWindowMessage()
   EXIT 10
