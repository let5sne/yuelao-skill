"""Validate CLI input without replacing bytes or guessing its encoding."""

import argparse
import json
import sys


def validate_text(text: str) -> None:
    text.encode("utf-8", errors="strict")
    if "\ufffd" in text:
        raise ValueError(
            "Input contains U+FFFD replacement characters; resend the original UTF-8 text."
        )


def validate_json_strings(value: object) -> None:
    if isinstance(value, str):
        validate_text(value)
    elif isinstance(value, dict):
        for key, item in value.items():
            validate_text(key)
            validate_json_strings(item)
    elif isinstance(value, list):
        for item in value:
            validate_json_strings(item)


def validate_object_pairs(pairs: list) -> dict:
    # Validate before duplicate keys are collapsed, so earlier values cannot hide damage.
    for key, value in pairs:
        validate_text(key)
        validate_json_strings(value)
    return dict(pairs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="also validate decoded JSON strings")
    parser.add_argument("--echo", action="store_true", help="emit the original bytes after validation")
    args = parser.parse_args()
    raw = sys.stdin.buffer.read()
    try:
        text = raw.decode("utf-8", errors="strict")
        validate_text(text)
        if args.json:
            # jq and the server accept a UTF-8 BOM; preserve its bytes when echoing.
            json_text = text[1:] if text.startswith("\ufeff") else text
            validate_json_strings(
                json.loads(json_text, object_pairs_hook=validate_object_pairs)
            )
    except UnicodeDecodeError:
        message = "Input is not valid UTF-8; save the original text as UTF-8 before retrying."
    except UnicodeEncodeError:
        message = "JSON contains an unpaired Unicode surrogate that could become U+FFFD; refusing input."
    except (json.JSONDecodeError, RecursionError):
        message = "Invalid JSON."
    except ValueError as error:
        message = str(error)
    else:
        if args.echo:
            sys.stdout.buffer.write(raw)
        return 0
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
