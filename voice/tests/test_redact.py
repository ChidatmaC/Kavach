from redact import redact


def test_codes_and_pins_removed():
    out = redact("They asked me for the code 482913 and my PIN is 4321")
    assert "482913" not in out and "4321" not in out
    assert "[number removed]" in out


def test_card_and_account_numbers_removed():
    out = redact("card 4111 1111 1111 1111 and account 123456789012, routing 021000021")
    assert not any(ch.isdigit() for ch in out), out


def test_spoken_digits_removed():
    out = redact("the code was four eight two nine one three okay")
    assert "four eight two" not in out and "okay" in out


def test_phone_numbers_removed():
    out = redact("he called from +1 555-555-0199 yesterday")
    assert "0199" not in out and "555" not in out


def test_alphanumeric_ids_removed():
    assert "AB123456" not in redact("my member id is AB123456")


def test_small_amounts_kept():
    out = redact("he wanted $50 and then 300 dollars in gift cards")
    assert "$50" in out and "300 dollars" in out


def test_empty():
    assert redact("") == ""
