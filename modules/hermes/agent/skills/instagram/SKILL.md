---
name: instagram
description: Read and send the user's Instagram DMs, browse their feed and stories, and post, through instagram.com in your browser, where they are logged in.
version: 1.0.0
author: personal-server-nixconfig
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [Instagram, social media, messaging]
---

# Instagram

There is no public API for a personal account: you use https://www.instagram.com
in your browser tools, like a person would. The browser keeps one profile, so
the user's session stays logged in between tasks.

## Logged in?

Open https://www.instagram.com/. If it shows the login form:

1. Go to https://www.instagram.com/accounts/login/.
2. `browser_vault` `list`: the Instagram login (from the user's 1Password
   vault for you). Type its username yourself, then `fill` for the password,
   then submit.
3. A code asked for: `browser_vault` `enter_code` with the same login.
4. Never ask for the password in chat, and never try to read it. No login in
   the vault, or Instagram asks for something else (a checkpoint, "was this
   you?", a code sent elsewhere): stop and tell the user to log in again with
   scripts/bootstrap-macos.sh, over SSH while looking at the Mac.

## Do

- Reading DMs: opening a thread marks its messages seen, and the user then
  gets no notification on their phone. So read the inbox without opening
  anything, in `browser_exec`. The site's old DM API answers 404 now
  (`/api/v1/direct_v2/inbox/` returns the logged-out page): read the page's
  own thread list instead, which carries who wrote, the last message and when.

  ```python
  # A narrow page shows only the empty "Your messages" panel: render wide.
  cdp('Emulation.setDeviceMetricsOverride', width=1280, height=900,
      deviceScaleFactor=1, mobile=False)
  goto_url('https://www.instagram.com/direct/inbox/')
  wait_for_load()
  print(page_info(), js('document.title'))
  print(js('''[...document.querySelectorAll('a[href^="/direct/t/"]')].map(a => {
    const text = (a.innerText || '').replace(/\\s+/g, ' ').trim();
    return text + '  ->  ' + a.getAttribute('href');
  })'''))
  ```

  One line per thread: the names, the newest message and its time, then the
  thread id the URL needs. Messages in a thread come from its `[role="main"]`
  text, which is why opening one marks it seen. A notification that names no
  sender (Instagram's own pushes rarely do) is answered from this list: find
  the line whose text matches the notification, and its names are who wrote.
  Requests from people the user does not follow are under "Requests" at the
  top of that page.
  An empty list means the page has not loaded (wait for it and read again) or
  the account is not logged in; `document.title` tells the two apart. Conclude
  nothing before both are ruled out.
- Sending: https://www.instagram.com/direct/t/<thread_id>/ (or the inbox,
  then the thread). Send with the thread's message box, then leave for the
  inbox.
- Stories: the circles at the top of the home feed; a person's at
  https://www.instagram.com/stories/<username>/.
- Profiles and posts: https://www.instagram.com/<username>/.
- Post a photo or video: the "Create" (+) button in the sidebar. The desktop
  site cannot post stories: say so, and offer a post instead.
- When a page does not respond to the browser tools, computer use on the
  browser window works too.

## Care

- You act as the user, in front of real people. Send a DM, post, comment,
  like or follow only when the user asked for that, and confirm the exact text
  and recipient first unless they gave both. @confirm@
- Go at a person's pace: no bulk actions, no scraping loops, a few seconds
  between actions. Instagram locks accounts that behave like bots.
