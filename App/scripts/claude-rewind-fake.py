#!/usr/bin/env python3
# A stand-in for Claude Code 2.1.x at its prompt, for the apptests: it draws a conversation and the
# input box, and Esc Esc opens a rewind menu drawn row for row like the real one (captured from
# 2.1.280, its list as 2.1.322 draws it): the message list ("❯ (current)" first, ↑ / ↓ moves, "↑ N more"),
# then the confirmation with its numbered options. Home jumps to the first message (⇧↑ did up to 2.1.280,
# and does nothing now: logged as "key shift-up"). "Restore conversation" drops the message and everything
# after it and puts its text in the input, like Claude Code. Every action goes to the log file, so a
# test can tell exactly what was chosen ("restore conversation 2", never "restore code").
#
#   claude-rewind-fake.py <spec.json> <log file>
#   spec: {"prompts": [...], "files": bool (a turn changed files: code options, default
#          "Restore code and conversation"), "input": "draft text",
#          "lag_ms": n (a key is handled at once, the screen shows it n ms later),
#          "tick": bool (a clock on screen redraws every 100ms, as "(6s ago)" does),
#          "direct": bool (no confirmation: Return on a message restores the conversation),
#          "close_on_pick": bool (Return on a message just closes the menu),
#          "working": "footer" | "spinner" (Claude is working; Esc stops it),
#          "takeback": bool (that Esc takes the last turn back, its text in the input),
#          "open_delay_ms": n (Esc Esc opens the menu only n ms later),
#          "slow_restore_ms": n (after Restore conversation, the prompt shows again only n ms later),
#          "slow_close_ms": n (after Restore conversation, the menu stays up n ms more),
#          "queued": "text" (a prompt queued while Claude works, as 2.1.280 shows it),
#          "bars": bool (2.1.280's own look: each prompt a full-width bar on a background color, a
#          "✻ Crunched for 3s · done Wednesday 11:42 PM" line under each reply, and the right-aligned
#          "● high · /effort" note right above the input box),
#          "orphans": [...] (bars: replies with no prompt under the first turn, as 2.1.280 draws the
#          turns a rewind removed after `claude --resume`)}
# Every key read is logged too ("key up", "key esc", …).
import json, os, select, sys, termios, time, tty, unicodedata

spec = json.load(open(sys.argv[1]))
LOG = open(sys.argv[2], 'a')
prompts = list(spec['prompts'])
files = spec.get('files', False)
draft = spec.get('input', '')
lag = spec.get('lag_ms', 0) / 1000.0
working = spec.get('working')
state = 'idle'        # idle | list | confirm
sel = len(prompts)    # list: index into prompts + [(current)]
opt = 0
last_esc = 0.0
hint = ''
started = time.time()
due = None            # when the next lagged redraw is due
opening = None        # when a late menu opens
restoring = None      # until when a slow restore hides the input box
closing = None        # until when a slow close keeps the menu up


def log(s):
    LOG.write(s + '\n')
    LOG.flush()


def cols():
    try:
        return os.get_terminal_size(1).columns
    except OSError:
        return 100


def entry(p, width):
    lines = p.split('\n')
    first = lines[0]
    if len(first) > width:
        return first[:width - 1] + '…'
    return first + ('…' if len(lines) > 1 else '')


def width(s):
    """Terminal cells: Hangul, CJK and fullwidth forms take two."""
    return sum(2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in s)


def options():
    o = ['Restore code and conversation', 'Restore conversation', 'Restore code'] if files else ['Restore conversation']
    return o + ['Summarize from here', 'Summarize up to here', 'Never mind']


def draw():
    w = cols()
    out = ['\033[2J\033[H']
    if spec.get('tick'):
        out.append('  clock %.1f\r\n' % (time.time() - started))
    bars = spec.get('bars')
    for p in prompts:
        lines = p.split('\n')
        if bars:
            # The bar: background color to the last column, the marker and text on it.
            for i, l in enumerate(lines):
                text = ('❯ ' if i == 0 else '  ') + l
                out.append('\033[48;5;254m\033[38;5;235m' + text + ' ' * max(0, w - width(text)) + '\033[0m\r\n')
            out.append('\r\n⏺ OK ' + lines[0][:24] + '\r\n\r\n✻ Crunched for 3s · done Wednesday 11:42 PM\r\n\r\n')
            if p == prompts[0]:
                for o in spec.get('orphans', []):
                    out.append('⏺ OK ' + o + '\r\n\r\n')
            continue
        out.append('❯ ' + lines[0] + '\r\n')
        for l in lines[1:]:
            out.append('  ' + l + '\r\n')
        out.append('\r\n⏺ OK ' + lines[0][:24] + '\r\n\r\n')
    if state == 'idle':
        rule = '─' * w
        if hint:
            out.append(' ' * max(0, w - len(hint) - 2) + hint + '\r\n')
        if spec.get('queued'):
            out.append('❯ ' + spec['queued'] + '\r\n  ctrl+x ctrl+s to send now\r\n')
        if working == 'spinner':
            out.append('✻ Working… (esc to interrupt)\r\n\r\n')
        foot = ' · esc to interrupt' if working == 'footer' else ' · ? for shortcuts'
        if restoring is not None:
            out.append('  Restoring…')
        else:
            shown = draft.replace('\n', '\r\n  ') or ('Press up to edit queued messages' if spec.get('queued') else '')
            if bars:
                note = '● high · /effort'
                out.append(' ' * (w - len(note) - 2) + note + '\r\n')
            out.append(rule + '\r\n❯ ' + shown + '\r\n' + rule + '\r\n  ⏸ manual mode on' + foot)
    else:
        out.append('▔' * w + '\r\n   Rewind\r\n\r\n')
        if state == 'list':
            out.append('   Restore the code and/or conversation to the point before…\r\n')
            items = prompts + [None]
            lo = max(0, min(sel - 1, len(items) - 3))
            hi = min(len(items), lo + 3)
            out.append('\r\n')
            if lo > 0:
                out.append('    ↑ %d more\r\n' % lo)
            for i in range(lo, hi):
                text = '(current)' if items[i] is None else entry(items[i], w - 14)
                out.append(('   ❯ ' if i == sel else '     ') + text + '\r\n')
                if items[i] is not None:
                    out.append('     No code changes\r\n')
                out.append('\r\n')
            if hi < len(items):
                out.append('    ↓ %d more\r\n' % (len(items) - hi))
            out.append('   Enter to continue · Esc to cancel')
        else:
            out.append('   Confirm you want to restore to the point before you sent this message:\r\n\r\n')
            for l in prompts[sel].split('\n')[:4]:
                out.append('   │ ' + l + '\r\n')
            out.append('   │ (%ds ago)\r\n\r\n' % (6 + int(time.time() - started)))
            out.append('   The conversation will be forked.\r\n')
            out.append('   The code will be restored in note.txt.\r\n\r\n' if files else '   The code will be unchanged.\r\n\r\n')
            for i, label in enumerate(options()):
                out.append(('   ❯ ' if i == opt else '     ') + '%d. %s\r\n' % (i + 1, label))
    sys.stdout.write(''.join(out))
    sys.stdout.flush()


def key(k):
    global state, sel, opt, last_esc, draft, hint, working, due, opening, restoring, closing
    log('key ' + k)
    now = time.time()
    if state == 'idle':
        if k == 'esc' and working:
            working = None
            if spec.get('takeback') and prompts:
                draft = prompts.pop()
                log('take back %d' % (len(prompts) + 1))
            else:
                log('interrupt')
            last_esc = 0.0
        elif k == 'esc':
            double = now - last_esc < 0.8
            last_esc = 0.0 if double else now
            if draft:
                if double:
                    draft, hint = '', ''
                    log('clear input')
                else:
                    hint = 'Esc again to clear'
            elif double and spec.get('open_delay_ms'):
                opening = now + spec['open_delay_ms'] / 1000.0
            elif double:
                state, sel = 'list', len(prompts)
                log('open')
        elif k == 'up':
            log('history up')  # what ↑ would do at the prompt: never wanted here
        elif k == 'ctrl-u':
            # Deletes back to the start of the cursor's (the last) line, as in Claude Code.
            draft = draft[:draft.rfind('\n') + 1] if '\n' in draft else ''
            log('clear input' if not draft.strip() else 'kill line')
            if not draft.strip():
                draft = ''
    elif state == 'list':
        if k == 'top':
            sel = 0
        elif k == 'bottom':
            sel = len(prompts)
        elif k == 'up':
            sel = max(0, sel - 1)
        elif k == 'down':
            sel = min(len(prompts), sel + 1)
        elif k == 'esc':
            state = 'idle'
            log('close')
        elif k == 'enter' and sel < len(prompts):
            log('pick %d' % (sel + 1))
            if spec.get('close_on_pick'):
                state = 'idle'
            elif spec.get('direct'):
                draft = prompts[sel]
                del prompts[sel:]
                log('restore conversation %d' % (sel + 1))
                state = 'idle'
            else:
                state, opt = 'confirm', 0
    elif state == 'confirm':
        if k == 'up':
            opt = max(0, opt - 1)
        elif k == 'down':
            opt = min(len(options()) - 1, opt + 1)
        elif k == 'esc':
            state = 'list'
        elif k == 'enter':
            label = options()[opt]
            log('choose %s %d' % (label, sel + 1))
            if label in ('Restore conversation', 'Restore code and conversation'):
                draft = prompts[sel]
                del prompts[sel:]
                log('restore %s %d' % ('code' if 'code' in label else 'conversation', sel + 1))
                if spec.get('slow_restore_ms'):
                    restoring = now + spec['slow_restore_ms'] / 1000.0
            if spec.get('slow_close_ms'):
                closing = now + spec['slow_close_ms'] / 1000.0
            else:
                state = 'idle'
    if lag:
        due = time.time() + lag
    else:
        draw()


fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    draw()
    while True:
        wait = None
        if due is not None:
            wait = max(0, due - time.time())
        if spec.get('tick'):
            wait = 0.1 if wait is None else min(wait, 0.1)
        if opening is not None:
            wait = max(0, opening - time.time()) if wait is None else min(wait, max(0, opening - time.time()))
        if restoring is not None:
            wait = max(0, restoring - time.time()) if wait is None else min(wait, max(0, restoring - time.time()))
        if closing is not None:
            wait = max(0, closing - time.time()) if wait is None else min(wait, max(0, closing - time.time()))
        r, _, _ = select.select([fd], [], [], wait)
        if closing is not None and time.time() >= closing:
            closing = None
            state = 'idle'
            draw()
        if restoring is not None and time.time() >= restoring:
            restoring = None
            draw()
        if opening is not None and time.time() >= opening:
            opening = None
            state, sel = 'list', len(prompts)
            log('open')
            draw()
        if due is not None and time.time() >= due:
            due = None
            draw()
        elif spec.get('tick') and not r:
            draw()
        if not r:
            continue
        data = os.read(fd, 1024)
        if not data:
            break
        i = 0
        while i < len(data):
            if data[i:i + 6] == b'\x1b[1;2A':
                key('shift-up'); i += 6
            elif data[i:i + 3] in (b'\x1b[H', b'\x1bOH'):
                key('top'); i += 3
            elif data[i:i + 6] == b'\x1b[1;2B':
                key('bottom'); i += 6
            elif data[i:i + 3] in (b'\x1b[A', b'\x1bOA'):
                key('up'); i += 3
            elif data[i:i + 3] in (b'\x1b[B', b'\x1bOB'):
                key('down'); i += 3
            elif data[i:i + 1] == b'\x1b':
                key('esc'); i += 1
            elif data[i:i + 1] in (b'\r', b'\n'):
                key('enter'); i += 1
            elif data[i:i + 1] == b'\x15':
                key('ctrl-u'); i += 1
            elif data[i:i + 1] == b'\x03':
                sys.exit(0)
            else:
                draft += data[i:i + 1].decode('utf-8', 'replace'); i += 1
                log('typed')
                draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
