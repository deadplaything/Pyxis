# Pyxis

Pyxis
A lightweight Abyssea chest opener for Final Fantasy XI (Ashita v4).


![Pyxis HUD](New%20folder%20(6)/pyxis-preview.png)




Select Blue, Gold, or Red chests by clicking their icons. The HUD shows nearby chest counts and your available Forbidden Keys. Press one macro to open enabled chests in range, one at a time.
Install
1. Put the pyxis folder (including its images folder) in Ashita/addons/.
2. Load it in game:
/addon load pyxis
Macro
/console py
Press once to start opening enabled chests within 5.9 yalms. Pyxis stops when there are no more eligible chests. Forbidden Keys must be in your main inventory.
Commands
Command	Description
/py	Open enabled nearby chests
/py stop	Stop opening
/py blue	Toggle Blue chests
/py gold	Toggle Gold chests
/py red	Toggle Red chests
/py hud	Show/hide HUD
/py status	Show current settings
/py reset	Clear attempted chest history


You can also use /py blue on or /py blue off (same for Gold and Red).
Note: Temporary-item chest deletion is not currently supported. Pyxis is for Ashita v4.
