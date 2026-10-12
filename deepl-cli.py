#!/usr/bin/env python3
"""Correct, rephrase and translate text with DeepL from the command line.

Uses DeepL's Python SDK (https://github.com/DeepL/deepl-python), installed with
pipx into a venv of its own, which this script re-runs itself with:

    pipx install deepl        # later: pipx upgrade deepl

The API key is the DEEPL_KEY=... line of the .env file next to this script
(~/scripts/.env, ignored by git); a Free key (ending in :fx) goes to
api-free.deepl.com by itself. Every command but usage and languages draws on
the key's monthly character quota.

correct only fixes spelling and grammar and changes as little as it can
(DeepL Write, /v2/write/correct). rephrase rewrites for clarity and style
(/v2/write/rephrase) and can reword whole sentences or even add content, so
read what it returns.

Text comes from the arguments, or from standard input when there are none (or
just "-"): files and pipes work, and so does pasting into the terminal (end
with Ctrl-D on an empty line). Only the result goes to standard output.

Examples:
  deepl-cli.py fix "I has a apple yesterday and it were tasty."
  deepl-cli.py fix -d < letter.txt          # -d: also show what changed
  deepl-cli.py fix -l en-GB "My favorite color is gray."
  deepl-cli.py rephrase -s business "hey, send me the report asap"
  deepl-cli.py tr de --informal "Good morning, how are you?"
  deepl-cli.py tr en-US < carta.txt > letter.txt
  wl-paste | deepl-cli.py fix | wl-copy     # correct the clipboard
  deepl-cli.py usage
"""
import argparse
import difflib
import os
import re
import sys

PROG = os.path.basename(sys.argv[0])
ENV_FILE = os.path.join(os.path.dirname(os.path.realpath(__file__)), ".env")
PIPX_VENV = os.path.join(
    os.environ.get("PIPX_HOME") or os.path.expanduser("~/.local/share/pipx"),
    "venvs", "deepl")
STYLES = ("simple", "business", "academic", "casual")
TONES = ("enthusiastic", "friendly", "confident", "diplomatic")

try:
    import deepl
except ImportError:
    # Not importable from this Python: re-run with the venv pipx made for the
    # SDK, unless that is the one already running.
    venv_python = os.path.join(PIPX_VENV, "bin", "python")
    if (os.path.exists(venv_python)
            and os.path.realpath(sys.prefix) != os.path.realpath(PIPX_VENV)):
        os.execv(venv_python,
                 [venv_python, os.path.abspath(__file__), *sys.argv[1:]])
    sys.exit(f"{PROG}: error: DeepL's Python SDK is missing; install it "
             "with: pipx install deepl\n"
             "(installed before a Python upgrade? then: pipx reinstall deepl)")


def fail(message):
    sys.exit(f"{PROG}: error: {message}")


def api_key():
    """The value of the DEEPL_KEY=... line in ENV_FILE."""
    try:
        with open(ENV_FILE, encoding="utf-8") as env:
            for line in env:
                name, _, value = (line.strip().removeprefix("export ")
                                  .partition("="))
                if name.strip() == "DEEPL_KEY" and value.strip():
                    return value.strip().strip("\"'")
    except OSError as e:
        fail(f"can't read the API key: {e}")
    fail(f"no DEEPL_KEY=... line in {ENV_FILE}")


def lang_code(value):
    """argparse type for language codes such as de, en-US, es-419, zh-Hant."""
    if not re.fullmatch(r"[A-Za-z]{2,3}(-[A-Za-z0-9]{2,4})?", value):
        raise argparse.ArgumentTypeError(
            f"{value!r} is not a language code like de, en-US or pt-BR")
    return value


def read_text(words):
    """The words joined by spaces, or standard input if none or just "-"."""
    if words and words != ["-"]:
        text = " ".join(words)
    else:
        if sys.stdin.isatty():
            print("Type or paste the text, then press Ctrl-D on an empty "
                  "line:", file=sys.stderr)
        text = sys.stdin.read()
    text = text.strip()
    if not text:
        fail("no text given")
    return text


def show_changes(before, after):
    """Word diff on standard error: removed text red and struck through,
    added text green, or wdiff's [-removed-]{+added+} where color is off."""
    if before == after:
        print("(no changes)", file=sys.stderr)
        return
    color = sys.stderr.isatty() and not os.environ.get("NO_COLOR")
    tokens = re.compile(r"\w+|\s+|[^\w\s]")
    a, b = tokens.findall(before), tokens.findall(after)
    diff = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, a, b, autojunk=False).get_opcodes():
        old, new = "".join(a[i1:i2]), "".join(b[j1:j2])
        if op == "equal":
            diff.append(old)
            continue
        if old:
            diff.append(f"\033[9;31m{old}\033[0m" if color else f"[-{old}-]")
        if new:
            diff.append(f"\033[32m{new}\033[0m" if color else f"{{+{new}+}}")
    print("".join(diff), file=sys.stderr)


def correct(client, args):
    if not hasattr(client, "correct_text"):
        fail("correct needs deepl 1.32 or newer; run: pipx upgrade deepl")
    text = read_text(args.text)
    result = client.correct_text(text, target_lang=args.lang)
    if args.diff:
        show_changes(text, result.text)
    print(result.text)


def rephrase(client, args):
    text = read_text(args.text)
    result = client.rephrase_text(text, target_lang=args.lang,
                                  style=args.style, tone=args.tone)
    if args.diff:
        show_changes(text, result.text)
    print(result.text)


def translate(client, args):
    text = read_text(args.text)
    result = client.translate_text(text, target_lang=args.target_lang,
                                   source_lang=args.source_lang,
                                   formality=args.formality)
    print(result.text)


def usage(client, args):
    chars = client.get_usage().character
    if not chars.valid:
        fail("DeepL reported no character quota for this key")
    print(f"{chars.count:,} of {chars.limit:,} characters used this billing "
          f"period, {chars.limit - chars.count:,} left")


def languages(client, args):
    print("TARGET_LANG codes (* = has formal/informal address):")
    for lang in client.get_target_languages():
        formality = " *" if lang.supports_formality else ""
        print(f"  {lang.code:<8} {lang.name}{formality}")
    print("--from takes the base codes only: EN, PT, ZH, ...")


def main():
    description, _, examples = __doc__.partition("Examples:")
    parser = argparse.ArgumentParser(
        description=description, epilog="Examples:" + examples,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(metavar="COMMAND", required=True)
    text_help = 'the text; read from standard input if omitted or "-"'
    lang_help = ("language or variant to write in, e.g. en-GB, en-US, pt-BR "
                 "(default: the text's own)")
    diff_help = "also show what changed, on standard error"

    p = commands.add_parser("correct", aliases=["fix"],
                            help="fix spelling and grammar only")
    p.add_argument("-l", "--lang", type=lang_code, help=lang_help)
    p.add_argument("-d", "--diff", action="store_true", help=diff_help)
    p.add_argument("text", nargs="*", help=text_help)
    p.set_defaults(run=correct)

    p = commands.add_parser("rephrase", aliases=["improve"],
                            help="rewrite for clarity and style")
    p.add_argument("-l", "--lang", type=lang_code, help=lang_help)
    p.add_argument("-d", "--diff", action="store_true", help=diff_help)
    style = p.add_mutually_exclusive_group()
    style.add_argument(
        "-s", "--style", metavar="STYLE",
        choices=[*STYLES, *(f"prefer_{s}" for s in STYLES)],
        help=f"{', '.join(STYLES)}; with a prefer_ prefix (prefer_business) "
             "a language without styles gets the default instead of an error")
    style.add_argument(
        "-t", "--tone", metavar="TONE",
        choices=[*TONES, *(f"prefer_{t}" for t in TONES)],
        help=f"{', '.join(TONES)}; prefer_ works as for --style")
    p.add_argument("text", nargs="*", help=text_help)
    p.set_defaults(run=rephrase)

    p = commands.add_parser("translate", aliases=["tr"],
                            help="translate into TARGET_LANG")
    p.add_argument("target_lang", metavar="TARGET_LANG", type=lang_code,
                   help='e.g. de, en-US, en-GB, es, pt-BR ("languages" '
                        "lists them all)")
    p.add_argument("-f", "--from", dest="source_lang", metavar="LANG",
                   type=lang_code,
                   help="the text's language, e.g. en, es (default: detected)")
    formality = p.add_mutually_exclusive_group()
    formality.add_argument("--formal", dest="formality", action="store_const",
                           const="prefer_more",
                           help="formal address (Sie, usted, vous) where the "
                                "language has it")
    formality.add_argument("--informal", dest="formality",
                           action="store_const", const="prefer_less",
                           help="informal address (du, tú, tu)")
    p.add_argument("text", nargs="*", help=text_help)
    p.set_defaults(run=translate)

    commands.add_parser(
        "usage", help="characters used and left this billing period"
    ).set_defaults(run=usage)
    commands.add_parser(
        "languages", help="language codes for translate"
    ).set_defaults(run=languages)

    args = parser.parse_args()
    client = deepl.DeepLClient(api_key())
    try:
        args.run(client, args)
    except deepl.AuthorizationException as e:
        fail(f"{e} (the key is DEEPL_KEY in {ENV_FILE})")
    except deepl.DeepLException as e:
        fail(e)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
