from kavach.redact import redact


def test_masks_codes_cards_accounts():
    t = redact("Your code is 482913. Card 4111 1111 1111 1111, acct 123456789012, PIN 1234, SSN 123-45-6789")
    for secret in ("482913", "4111", "123456789012", "1234", "123-45-6789"):
        assert secret not in t
    assert "[code]" in t and "[card number]" in t and "[ssn]" in t


def test_spaced_code_and_password():
    t = redact("the code is 4 8 2 9 1 3 and my password: hunter2")
    assert "4 8 2 9" not in t and "hunter2" not in t


def test_keeps_money_and_phone_numbers():
    t = redact("Pay $4.35 to avoid a $1,200 fee, call +15555550199")
    assert "$4.35" in t and "$1,200" in t and "+15555550199" in t
