#!/usr/bin/env python3
"""Builds the private browser's ad/tracker blocking rules (WebKit content-blocker JSON).

Sources (downloaded by you, bundled into the app; the app never fetches lists itself):
  hosts           StevenBlack/hosts            MIT                  https://github.com/StevenBlack/hosts
  easylist.txt    EasyList                     GPLv3 / CC BY-SA 3.0 https://easylist.to
  easyprivacy.txt EasyPrivacy                  GPLv3 / CC BY-SA 3.0 https://easylist.to

    python3 Tools/make-blocklist.py hosts easylist.txt easyprivacy.txt

Writes LiveSubs/Resources/AdBlock/blocklist-network.json and blocklist-cosmetic.json (two lists,
each under WebKit's 150,000-rule limit). Only the Adblock Plus syntax WebKit can express is
converted; anything else is skipped rather than guessed, so no rule can break a page.
"""

import json
import re
import sys

hosts_path, easylist_paths = sys.argv[1], sys.argv[2:]
OUT = "LiveSubs/Resources/AdBlock/"


def host_rule(d):
    return {
        "trigger": {
            "url-filter": "^[^:]+://+([^:/]+\\.)?"
            + re.escape(d).replace("\\-", "-")
            + "[:/]"
        },
        "action": {"type": "block"},
    }


# --- 1. Domains from the hosts list (merged: a parent domain covers its subdomains) ---------
domains = set()
for line in open(hosts_path, encoding="utf-8", errors="ignore"):
    parts = line.split("#")[0].split()
    if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1"):
        d = parts[1].strip().lower().rstrip(".")
        if (
            d
            and d
            not in (
                "localhost",
                "localhost.localdomain",
                "0.0.0.0",
                "broadcasthost",
                "local",
            )
            and re.fullmatch(r"[a-z0-9._-]+", d)
        ):
            domains.add(d)

# --- 2. EasyList / EasyPrivacy ------------------------------------------------------------
TYPES = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "subdocument": "document",
    "xmlhttprequest": "fetch",
    "media": "media",
    "font": "font",
    "popup": "popup",
    "websocket": "websocket",
    "ping": "ping",
    "other": "raw",
    "object": "raw",
}
SAFE_SELECTOR = re.compile(r'^[A-Za-z0-9_\-#.\[\]="\'^$*~|:>+ ,()]+$')
UNSUPPORTED_PSEUDO = re.compile(
    r":(-abp-|has-text|xpath|upward|remove|style|matches-|contains|min-text|watch-attr|"
    r"nth-ancestor|others|if|matches-path|has\()"
)


def pattern_to_regex(p):
    """ABP URL pattern -> WebKit url-filter (a regex subset), or None if not expressible."""
    if p.startswith("/") and p.endswith("/") and len(p) > 2:
        return None  # raw regexes: skipped (WebKit's subset is narrower)
    anchor_domain = p.startswith("||")
    anchor_start = not anchor_domain and p.startswith("|")
    p = p[2:] if anchor_domain else (p[1:] if anchor_start else p)
    anchor_end = p.endswith("|")
    p = p[:-1] if anchor_end else p
    if not p or "|" in p:
        return None
    out = []
    for ch in p:
        if ch == "*":
            out.append(".*")
        elif ch == "^":
            out.append("[^a-zA-Z0-9_.%-]")
        elif ch in ".+?()[]{}\\$":
            out.append("\\" + ch)
        else:
            out.append(ch)
    body = "".join(out)
    if body.endswith("[^a-zA-Z0-9_.%-]"):
        body = (
            body[: -len("[^a-zA-Z0-9_.%-]")] + "([^a-zA-Z0-9_.%-]|$)" if False else body
        )  # keep simple
    if anchor_domain:
        body = "^[^:]+://+([^:/]+\\.)?" + body
    elif anchor_start:
        body = "^" + body
    if anchor_end:
        body += "$"
    if len(body) < 6:
        return None  # too generic to be safe
    return body


network, exceptions, generic_css, site_css = [], [], [], {}
for path in easylist_paths:
    for raw in open(path, encoding="utf-8", errors="ignore"):
        line = raw.strip()
        if not line or line.startswith("!") or line.startswith("["):
            continue
        if (
            "#@#" in line
            or "#?#" in line
            or "#$#" in line
            or "#%#" in line
            or "$$" in line
        ):
            continue  # cosmetic exceptions / extended / scriptlets: skipped
        if "##" in line:
            doms, sel = line.split("##", 1)
            if not SAFE_SELECTOR.match(sel) or UNSUPPORTED_PSEUDO.search(sel):
                continue
            if not doms:
                generic_css.append(sel)
            else:
                ds = [d.strip() for d in doms.split(",") if d.strip()]
                if any(d.startswith("~") for d in ds):
                    continue
                site_css.setdefault(tuple(sorted(ds)), []).append(sel)
            continue
        is_exception = line.startswith("@@")
        if is_exception:
            line = line[2:]
        pattern, _, opts = line.partition("$")
        trigger, ok = {}, True
        load_types, res_types, if_dom, unless_dom = [], [], [], []
        for o in [o for o in opts.split(",") if o] if opts else []:
            neg = o.startswith("~")
            name = o.lstrip("~")
            if name == "third-party":
                (load_types.append("first-party" if neg else "third-party"))
            elif name in ("first-party", "1p"):
                load_types.append("third-party" if neg else "first-party")
            elif name.startswith("domain="):
                for d in name[7:].split("|"):
                    (unless_dom if d.startswith("~") else if_dom).append(
                        "*" + d.lstrip("~")
                    )
            elif name in TYPES and not neg:
                res_types.append(TYPES[name])
            elif name in ("match-case",):
                trigger["url-filter-is-case-sensitive"] = True
            elif name in ("important", "all", "document", "doc"):
                pass
            else:
                ok = False
                break  # options WebKit can't express: skip the rule
        if not ok:
            continue
        rx = pattern_to_regex(pattern)
        if not rx:
            continue
        trigger["url-filter"] = rx
        if len(set(load_types)) == 1:
            trigger["load-type"] = [load_types[0]]
        if res_types:
            trigger["resource-type"] = sorted(set(res_types))
        if if_dom and unless_dom:
            continue
        if if_dom:
            trigger["if-domain"] = if_dom
        if unless_dom:
            trigger["unless-domain"] = unless_dom
        rule = {
            "trigger": trigger,
            "action": {"type": "ignore-previous-rules" if is_exception else "block"},
        }
        (exceptions if is_exception else network).append(rule)

# YouTube: its ads come from its own servers, so they need their own paths.
# (One rule per path: WebKit's regex subset has no "a|b" disjunctions.)
youtube = [
    r"^https?://([^/]+\.)?youtube\.com/" + path
    for path in (
        "api/stats/ads",
        "pagead/",
        "ptracking",
        "get_midroll_",
        "youtubei/v1/log_event",
    )
] + [
    r"^https?://([^/]+\.)?" + host + "/"
    for host in (
        r"doubleclick\.net",
        r"googleadservices\.com",
        r"googlesyndication\.com",
    )
]
network += [
    {"trigger": {"url-filter": u}, "action": {"type": "block"}} for u in youtube
]
site_css[("youtube.com",)] = site_css.get(("youtube.com",), []) + [
    "ytm-promoted-sparkles-web-renderer",
    "ytm-companion-ad-renderer",
    "ad-slot-renderer",
    "ytm-promoted-video-renderer",
    ".ytp-ad-overlay-container",
    "#player-ads",
    "ytd-ad-slot-renderer",
    "ytm-ad-slot-renderer",
    ".ytd-banner-promo-renderer",
    "ytd-promoted-sparkles-web-renderer",
]

kept = sorted(
    d
    for d in domains
    if not any(".".join(d.split(".")[i:]) in domains for i in range(1, d.count(".")))
)
# Two network lists, each under WebKit's 150,000-rule limit; exceptions last, as WebKit requires.
host_rules = [host_rule(d) for d in kept]
network_rules = network + exceptions

# Small batches: WebKit drops a whole css-display-none rule if any one selector in it is
# invalid, so one odd selector should cost at most a few others.
CORE = (".adsbygoogle, ins.adsbygoogle, [id^='google_ads_iframe'], [id^='div-gpt-ad'], .ad-slot, .ad-banner, "
        ".ad-container, [data-ad-slot], [data-google-query-id], .taboola, .OUTBRAIN, .outbrain, .sticky-ad, .adhesion-ad")
cosmetic = [{"trigger": {"url-filter": ".*"}, "action": {"type": "css-display-none", "selector": CORE}}]
generic_css = [g for g in generic_css if ':' not in g or re.fullmatch(r'[^:]*(:(not|nth-child|nth-of-type|first-child|last-child)\([^()]*\)[^:]*)*', g)]
for i in range(0, len(generic_css), 20):
    cosmetic.append(
        {
            "trigger": {"url-filter": ".*"},
            "action": {"type": "css-display-none", "selector": ", ".join(generic_css[i : i + 20])},
        }
    )
for doms, sels in site_css.items():
    for i in range(0, len(sels), 20):
        cosmetic.append(
            {
                "trigger": {"url-filter": ".*", "if-domain": ["*" + d for d in doms]},
                "action": {
                    "type": "css-display-none",
                    "selector": ", ".join(sels[i : i + 20]),
                },
            }
        )

json.dump(host_rules, open(OUT + "blocklist-hosts.json", "w"), separators=(",", ":"))
json.dump(
    network_rules, open(OUT + "blocklist-network.json", "w"), separators=(",", ":")
)
json.dump(cosmetic, open(OUT + "blocklist-cosmetic.json", "w"), separators=(",", ":"))
print(
    f"network: {len(kept)} host rules + {len(network)} EasyList/EasyPrivacy/YouTube rules + {len(exceptions)} exceptions"
    f" = {len(network_rules)}; cosmetic: {len(generic_css)} generic + {sum(map(len, site_css.values()))} site selectors"
    f" in {len(cosmetic)} rules"
)
