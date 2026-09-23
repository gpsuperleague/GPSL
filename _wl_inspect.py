# -*- coding: utf-8 -*-
from pathlib import Path
import re
t = Path(r"D:\GPSL_Cursor\waiting_list.js").read_text(encoding="utf-8")
print("lines", len(t.splitlines()))
print("rpc", re.findall(r'rpc\("([^"]+)"', t))
print("ids", re.findall(r'getElementById\("([^"]+)"', t))
print("on_board refs", t.count("on_board"), t.count("I'm on board"), t.count("Invited"))
