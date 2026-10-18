use sure_desktop_lib::deep_link::{parse, parse_sso_callback, resolve, SsoCallback};
use sure_desktop_lib::servers::base_covers;

fn saved_servers<'a>(servers: &'a [&'a str]) -> impl Fn(&str) -> bool + 'a {
    let servers: Vec<String> = servers.iter().map(|s| s.to_string()).collect();
    move |url| servers.iter().any(|base| base_covers(base, url))
}

#[test]
fn parses_server_and_path() {
    let t = parse("sure://app.example.com/accounts/123").unwrap();
    assert_eq!(t.server, "https://app.example.com");
    assert_eq!(t.path, "/accounts/123");
}

#[test]
fn parses_with_port_and_defaults_root_path() {
    let t = parse("sure://localhost:3000").unwrap();
    assert_eq!(t.server, "https://localhost:3000");
    assert_eq!(t.path, "/");
}

#[test]
fn rejects_other_schemes() {
    assert!(parse("https://app.example.com/x").is_none());
    assert!(parse("sureapp://oauth/callback").is_none());
}

#[test]
fn resolves_document_and_transaction_links_to_saved_servers() {
    let known = saved_servers(&["https://app.example.com"]);
    for (link, expected) in [
        (
            "sure://app.example.com/documents/9f1c",
            "https://app.example.com/documents/9f1c",
        ),
        (
            "sure://app.example.com/transactions/42",
            "https://app.example.com/transactions/42",
        ),
        (
            "sure://app.example.com/sure/documents/9f1c",
            "https://app.example.com/sure/documents/9f1c",
        ),
    ] {
        let target = resolve(link, &known).expect("link resolves");
        assert_eq!(format!("{}{}", target.server, target.path), expected);
    }
}

#[test]
fn resolves_an_http_server_because_the_link_carries_no_scheme() {
    let known = saved_servers(&["http://localhost:3000"]);
    let target = resolve("sure://localhost:3000/transactions/7", &known).expect("http server resolves");
    assert_eq!(target.server, "http://localhost:3000");
    assert_eq!(target.path, "/transactions/7");
}

#[test]
fn prefers_https_when_both_schemes_are_saved() {
    let known = saved_servers(&["http://pay.example.com", "https://pay.example.com"]);
    let target = resolve("sure://pay.example.com/transactions/7", &known).unwrap();
    assert_eq!(target.server, "https://pay.example.com");
}

#[test]
fn refuses_a_server_the_user_has_not_saved() {
    let known = saved_servers(&["https://app.example.com"]);
    assert!(resolve("sure://evil.example/documents/1", &known).is_none());
}

#[test]
fn preserves_a_documents_query_and_fragment() {
    let t = parse("sure://app.example.com/documents/abc?entry_id=42#receipt").unwrap();
    assert_eq!(t.path, "/documents/abc?entry_id=42#receipt");
}

#[test]
fn parses_sso_callback_code() {
    match parse_sso_callback("sure://sso/callback?code=abc123") {
        Some(SsoCallback::Code(c)) => assert_eq!(c, "abc123"),
        _ => panic!("expected code"),
    }
}

#[test]
fn parses_sso_callback_error() {
    match parse_sso_callback("sure://sso/callback?error=account_not_linked") {
        Some(SsoCallback::Error(e)) => assert_eq!(e, "account_not_linked"),
        _ => panic!("expected error"),
    }
}

#[test]
fn sso_callback_rejects_non_sso_and_other_schemes() {
    assert!(parse_sso_callback("sure://app.example.com/accounts").is_none());
    assert!(parse_sso_callback("sureapp://sso/callback?code=x").is_none());
    assert!(parse_sso_callback("sure://sso/callback").is_none());
}
