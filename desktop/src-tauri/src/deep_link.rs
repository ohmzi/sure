use url::Url;

pub struct DeepLinkTarget {
    pub server: String,
    pub path: String,
}

/// The result of an SSO handoff deep link: `sure://sso/callback?code=...` returns
/// `Ok(code)`, `sure://sso/callback?error=...` returns `Err(error)`.
pub enum SsoCallback {
    Code(String),
    Error(String),
}

/// Parse a `sure://sso/callback` deep link, or None if it is not one.
pub fn parse_sso_callback(url: &str) -> Option<SsoCallback> {
    let parsed = Url::parse(url).ok()?;
    if parsed.scheme() != "sure" || parsed.host_str() != Some("sso") || parsed.path() != "/callback" {
        return None;
    }
    let mut code = None;
    let mut error = None;
    for (k, v) in parsed.query_pairs() {
        match k.as_ref() {
            "code" => code = Some(v.into_owned()),
            "error" => error = Some(v.into_owned()),
            _ => {}
        }
    }
    match (code, error) {
        (Some(c), _) => Some(SsoCallback::Code(c)),
        (None, Some(e)) => Some(SsoCallback::Error(e)),
        _ => None,
    }
}

/// A Sure link has no scheme for the server address, so both HTTPS and HTTP
/// are possible. HTTPS comes first; `resolve` picks the one the user saved.
const SERVER_SCHEMES: [&str; 2] = ["https", "http"];

fn parse_sure_url(url: &str) -> Option<Url> {
    let parsed = Url::parse(url).ok()?;
    (parsed.scheme() == "sure").then_some(parsed)
}

/// Keep the query and fragment: a document viewer can carry `?entry_id=` and
/// receipt links can point at the page's anchor.
fn path_with_query_and_fragment(parsed: &Url) -> String {
    let mut path = if parsed.path().is_empty() {
        "/".to_string()
    } else {
        parsed.path().to_string()
    };
    if let Some(query) = parsed.query() {
        path.push('?');
        path.push_str(query);
    }
    if let Some(fragment) = parsed.fragment() {
        path.push('#');
        path.push_str(fragment);
    }
    path
}

/// Every destination a `sure://` link could mean, preferred first.
pub fn candidates(url: &str) -> Vec<DeepLinkTarget> {
    if !url.starts_with("sure://") {
        return Vec::new();
    }
    let Some(parsed) = parse_sure_url(url) else {
        return Vec::new();
    };
    let Some(host) = parsed.host_str() else {
        return Vec::new();
    };
    let authority = match parsed.port() {
        Some(port) => format!("{host}:{port}"),
        None => host.to_string(),
    };
    let path = path_with_query_and_fragment(&parsed);
    SERVER_SCHEMES
        .iter()
        .map(|scheme| DeepLinkTarget {
            server: format!("{scheme}://{authority}"),
            path: path.clone(),
        })
        .collect()
}

/// The first candidate served by a saved server. Gating the whole destination
/// keeps a malicious link from loading an arbitrary origin in the main webview.
pub fn resolve(url: &str, is_known: impl Fn(&str) -> bool) -> Option<DeepLinkTarget> {
    candidates(url)
        .into_iter()
        .find(|target| is_known(&format!("{}{}", target.server, target.path)))
}

pub fn parse(url: &str) -> Option<DeepLinkTarget> {
    candidates(url).into_iter().next()
}
