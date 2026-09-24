src = "ÜüÖöÔôÄäÉéÈèÊêËëÍíÓóÚúÇçÀàÂâÃãÑñŞşĞğİı’‘`´ʼ"
dest_from_file = "UuOoOoAaEeEeEeIiOoUuCcAaAaAaNnSsGgIi'''''''"  # as written in E'...'''''''  - ambiguous
# What Postgres E'Uu...Ii'''''''  parses to:
# Inside E'...' the sequence '' is one quote. So after Ii: '' '' '' '  = three quotes then end?
# Actually: E'Ii''''''' 
# chars after Ii: position by position in source text `'''''''` (7 quote chars)
# '' -> '
# '' -> '
# '' -> '
# ' -> closes string
# So dest ends with 3 apostrophes. Length = 34+6+3 = 43
# src length with 5 apostrophe-like = 34+6+5 = 45 MISMATCH

base = "ÜüÖöÔôÄäÉéÈèÊêËëÍíÓóÚúÇçÀàÂâÃãÑñ"
extra = "ŞşĞğİı"
apos = "’‘`´ʼ"
print("base", len(base))
print("with turkish", len(base+extra))
print("with apos", len(base+extra+apos))
print("dest base", len("UuOoOoAaEeEeEeIiOoUuCcAaAaAaNn"))
print("dest + SsGgIi", len("UuOoOoAaEeEeEeIiOoUuCcAaAaAaNnSsGgIi"))
print("dest + 3 apos", len("UuOoOoAaEeEeEeIiOoUuCcAaAaAaNnSsGgIi") + 3)
