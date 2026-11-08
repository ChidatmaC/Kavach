from kavach.signals import check_link, extract_signals, extract_urls, registrable_domain, to_e164


def test_risky_ending_and_brand_hyphen_is_high():
    r = check_link("https://txtag-pay.top/inv/88213")
    assert r.domain == "txtag-pay.top"
    assert "risky_ending" in r.flags and "brand_hyphen" in r.flags
    assert r.risk == "high"


def test_lookalike_spelling():
    assert "lookalike_spelling" in check_link("http://paypa1.com/login").flags
    assert check_link("http://amaz0n.com").risk == "high"


def test_shortener_is_flagged():
    r = check_link("https://bit.ly/3xYz")
    assert "url_shortener" in r.flags and r.risk in ("medium", "high")


def test_official_domain_is_low():
    for u in ("https://www.usps.com/track", "https://reportfraud.ftc.gov", "https://www.chase.com"):
        assert check_link(u).risk == "low", u


def test_ip_and_punycode():
    assert check_link("http://192.168.4.20/pay").risk == "high"
    assert "punycode" in check_link("http://xn--pple-43d.com").flags


def test_plain_domain_unflagged():
    assert check_link("https://example.com").risk == "low"


def test_url_extraction_and_domains():
    t = "Pay now at txtag-pay.top/inv/1 or https://www.USPS-redelivery.info/x. Email me at a@b.com, e.g. tomorrow."
    urls = extract_urls(t)
    assert any("txtag-pay.top" in u for u in urls)
    assert any("usps-redelivery.info" in u.lower() for u in urls)
    assert not any("b.com" in u for u in urls)
    sig = extract_signals(t)
    assert sig.domains == ["txtag-pay.top", "usps-redelivery.info"]


def test_registrable_domain_multi_suffix():
    assert registrable_domain("https://a.b.example.co.uk/x") == "example.co.uk"
    assert registrable_domain("pay.txtag-pay.top") == "txtag-pay.top"


def test_phone_normalization():
    assert to_e164("(555) 555-0199") == "+15555550199"
    assert to_e164("+1 555 555 0199") == "+15555550199"
    assert extract_signals("call 555-555-0188 now").phones_in_text == ["+15555550188"]
