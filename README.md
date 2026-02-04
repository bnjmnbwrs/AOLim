# AOLim
Buddy list addon for FFXI (Ashita)
AOLim – AIM-Style Tell UI for FFXI (Ashita)
==========================================

Addon Name: AOLim
Author: Ben
Platform: Ashita (FFXI Private Servers)
Category: UI / Communication (QoL)


OVERVIEW
--------
AOLim is a lightweight, UI-only Ashita addon that provides an optional
AIM-style interface for /tell communication in Final Fantasy XI.

It allows players to:
- View tells in a dedicated window
- Organize contacts into groups
- Chat using tabbed conversations
- See unread message indicators
- Perform best-effort online checks using /sea all

AOLim does NOT automate gameplay and does NOT perform any actions without
explicit user input.


FEATURES
--------
- Dedicated IM-style window for /tell chat
- Buddy list with custom groups (Friends, Shell, etc.)
- Tabbed conversations per buddy
- Flashing ★ indicator for unread messages
- Best-effort online/offline status via /sea all
- Optional auto-watch mode (rate-limited)
- Right-click context menus for buddies
- Multiline chat input
  - Enter = Send
  - Shift + Enter = New line
- Persistent UI settings and buddy list


WHAT THIS ADDON DOES NOT DO
---------------------------
- No combat automation
- No movement or targeting automation
- No macros or decision-making logic
- No packet injection or memory modification
- No background polling without user visibility
- No long-term chat history logging


INSTALLATION
------------
1. Create the folder:
   Ashita/addons/aolim/

2. Place the following files inside:
   - aolim.lua
   - aolim_settings.lua
   - README.txt

3. Launch the game using Ashita.

4. In game, load the addon:
   /addon load aolim

5. Toggle the window:
   /aolim


COMMAND LIST
------------

GENERAL
- /aolim
  Toggle the AOLim window

- /aolim open
  Open the AOLim window

- /aolim close
  Close the AOLim window

- /aolim help
  Show help text in chat


BUDDY MANAGEMENT
- /aolim add <name>
  Add a buddy to the default Friends group

- /aolim add <name> <group>
  Add a buddy to a specific group

- /aolim del <name>
  Remove a buddy

- /aolim remove <name>
  Alias for /aolim del <name>


GROUPS
- /aolim group add <group>
  Create a new group

- /aolim group del <group>
  Delete a group (buddies move to Friends)

- /aolim group remove <group>
  Alias for /aolim group del <group>

NOTE:
- The default "Friends" group cannot be deleted.


PRESENCE / ONLINE STATUS
------------------------
Presence is best-effort and based on /sea all <name> queries.

- /aolim ping <name>
  Manually queue a /sea all check

- /aolim watch
  Toggle automatic presence checking

- /aolim watch on
  Enable automatic presence checking

- /aolim watch off
  Disable automatic presence checking

- /aolim interval <seconds>
  Set auto-watch interval (3–300 seconds)


WINDOW / UI
-----------
- /aolim lock
  Lock or unlock window position and size

- /aolim clear
  Clear all chat conversations

- /aolim clear <name>
  Clear chat for a specific buddy


IN-UI CONTROLS
--------------
- Click a buddy: Open chat tab
- Right-click a buddy:
  - Open Chat
  - Ping (/sea)
  - Move to Group
  - Remove

- Enter: Send message
- Shift + Enter: New line
- Unread messages:
  - Flashing ★ indicator on buddy list and tab


ONLINE STATUS INDICATORS
------------------------
[ON]  = Confirmed online via /sea or inbound tell
[OFF] = Confirmed offline via /sea
[?]   = Unknown / not checked recently


DATA STORAGE
------------
AOLim stores only:
- Buddy names
- Group names
- Window position and size
- Presence settings

No chat history is persisted across sessions.


COMPATIBILITY
-------------
- Designed for Ashita-based FFXI private servers
- Tested on Eden / WingsXI
- HorizonXI approval required before use


DISCLAIMER
----------
This addon is intended purely as a quality-of-life communication tool.
It does not provide gameplay advantages and does not bypass server rules.


END OF FILE
-----------
