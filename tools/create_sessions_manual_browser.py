#!/usr/bin/env python3
"""
Open a fresh browser for each account and wait for you to complete login.

Usage:
  python3 tools/create_sessions_manual_browser.py accounts.json --append sessions.jsonl

Input:
  [{"label": "public_handle_or_label"}, {"label": "second_label"}]

Use "label", "handle", or "public_username" as the local label in
sessions.jsonl. Login with whatever X asks for in the browser: phone number,
email, username, SMS, TOTP, captcha, passkey, etc.
"""

import argparse
import asyncio
import json
import sys

import nodriver as uc


def extract_user_id(cookies_dict):
    twid = cookies_dict.get("twid", "").strip('"')
    for prefix in ("u=", "u%3D"):
        if prefix in twid:
            return twid.split(prefix, 1)[1].split("&", 1)[0].strip('"')
    return None


def is_x_cookie(cookie):
    domain = (getattr(cookie, "domain", "") or "").lower().lstrip(".")
    return domain == "x.com" or domain.endswith(".x.com") or domain == "twitter.com" or domain.endswith(".twitter.com")


def x_cookies_dict(cookies):
    return {cookie.name: cookie.value for cookie in cookies if is_x_cookie(cookie)}


def cookie_header(cookies_dict):
    return "; ".join(f"{name}={value}" for name, value in sorted(cookies_dict.items()))


async def wait_for_session(browser, username, timeout):
    for _ in range(timeout):
        cookies = await browser.cookies.get_all()
        cookies_dict = x_cookies_dict(cookies)

        if "auth_token" in cookies_dict and "ct0" in cookies_dict:
            session = {
                "kind": "cookie",
                "username": username,
                "id": extract_user_id(cookies_dict),
                "auth_token": cookies_dict["auth_token"],
                "ct0": cookies_dict["ct0"],
                "cookie_header": cookie_header(cookies_dict),
            }
            return session

        await asyncio.sleep(1)

    raise TimeoutError("Timed out waiting for X login cookies")


async def start_browser(retries=5, delay=3):
    last_error = None
    for attempt in range(1, retries + 1):
        try:
            return await uc.start(headless=False, no_sandbox=True)
        except Exception as error:
            last_error = error
            if attempt < retries:
                print(
                    f"[!] Browser failed to start (attempt {attempt}/{retries}), "
                    f"retrying in {delay}s...",
                    file=sys.stderr,
                )
                await asyncio.sleep(delay)
    raise last_error


async def capture_one(index, total, username, timeout):
    print(
        f"[*] Account {index}/{total}: complete login in the opened browser window.",
        file=sys.stderr,
    )
    browser = await start_browser()
    try:
        await browser.get("https://x.com/i/flow/login")
        return await wait_for_session(browser, username, timeout)
    finally:
        browser.stop()


def account_label(account, index):
    return (
        account.get("label")
        or account.get("handle")
        or account.get("public_username")
        or f"account-{index}"
    )


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("accounts_file")
    parser.add_argument("--append", default="sessions.jsonl")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()

    with open(args.accounts_file) as f:
        accounts = json.load(f)

    if not isinstance(accounts, list) or len(accounts) == 0:
        raise SystemExit("accounts file must be a non-empty JSON array")

    written = 0
    for i, account in enumerate(accounts, 1):
        username = account_label(account, i)
        try:
            session = await capture_one(i, len(accounts), username, args.timeout)
            with open(args.append, "a") as f:
                f.write(json.dumps(session) + "\n")
            written += 1
            print(f"[*] Account {i}/{len(accounts)}: session saved.", file=sys.stderr)
        except Exception as error:
            print(f"[!] Account {i}/{len(accounts)}: {error}", file=sys.stderr)

    print(f"[*] Wrote {written}/{len(accounts)} sessions to {args.append}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())
