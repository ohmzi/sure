# Connecting a bank feed with SimpleFIN

Sure uses **SimpleFIN** as its only bank aggregator (spec D12). The
protocol is open and read-only; the fork ships the `Provider::Simplefin`
client, so the app side needs no extra component. Which *bridge* serves it is
the decision recorded below.

## Which "bridge" is used, and why

A SimpleFIN *bridge* is the component that authenticates to your banks (OAuth,
no screen-scraping) and answers the protocol's `/info`, `/create`,
`/claim/{token}` and `/accounts` endpoints. It is the only party that ever
holds a bank token.

**Decision status: pending owner sign-off (M5 Task 1; probe run at execution
time, 2026-10-11; recorded as BLOCKED-ON-OWNER in the M5 task report).** Two
branches were probed per §16.3:

- **Branch A — a maintained, self-hostable, bank-connecting SimpleFIN server.**
  Not available at probe time. The protocol spec
  (`https://www.simplefin.org/protocol-v1.html`) defines the four endpoints and
  ships no server. The projects that carry "simplefin bridge" in their name are
  consumers or aggregators of an existing access URL, not bank connectors
  (`steveredden/simplefin_to_maybe`, `righteffort/simplefin-aggregator`); the
  one self-hosted bank-connecting server found
  (`tomerh2001/israeli-banks-simplefin-bridge`) covers Israeli banks only, via
  screen-scraping, and `gi-os/simplefin-plaid` is a SimpleFIN v2 wrapper around
  Plaid that this app's pinned v1 client cannot use. Branch A wins whenever a
  maintained server for this household's institutions exists.
- **Branch B — the hosted SimpleFIN Bridge.** The only bank-connecting service
  linked from the app (Settings → Providers → SimpleFIN).

**Branch B is a recorded deviation from §4**, which still mandates a
self-hosted bridge container in the same project. It is permitted by **D12**,
which already carries this hosted-bridge fallback with the owner's sign-off,
and by §16.3. With the hosted bridge, the operator of that service holds the
per-bank access token (a revocable bank-access token, not a bank login).

The decision is **not closed**. It closes only when (1) the owner's explicit
sign-off for Branch B is on record **and** (2) the §4 amendment (spec:109)
lands with the controller. The exact sign-off text the owner must give:

> I approve Branch B for M5 Task 1: Sure connects banks through the
> hosted SimpleFIN Bridge. I accept that the bridge operator holds each bank's
> per-bank access token (revocable; never a bank login), and I record this as a
> deviation from §4, permitted by D12 and §16.3. I also approve the §4
> amendment (spec:109) replacing the self-hosted-bridge mandate.

## Credential path

1. Sign up at the SimpleFIN Bridge and connect each bank through its official
   consent flow.
2. Create a **setup token** for this app. The token is a one-time, base64
   string; it is single-use and expires.
3. In Sure: **Settings → Providers → SimpleFIN**, paste the token, save.
4. The app claims the token (`Provider::Simplefin#claim_access_url`), receives
   an **access URL** with embedded Basic-auth credentials, and stores it
   encrypted (`simplefin_items.access_url`, deterministic encrypt). The access
   URL never appears in a tracked file or a log; it is a database value.
5. Choose which returned accounts to link (Settings → Providers, or the
   accounts page), then let the first sync pull history.

Never retry a failed claim (`SimplefinConnectionUpdateJob`) — the setup token is
single-use and a retry burns it; mint a new token instead.

## Rotating / reconnecting

If the access URL is revoked, open the SimpleFIN item, provide a **new setup
token**, and save. This updates the existing item in place and preserves all
account linkages.

## Self-hosted protocol bridge (unsupported escape hatch)

Because `claim_access_url` POSTs to whatever URL the setup token encodes, an
operator who runs their own SimpleFIN-protocol server (loopback-only, never
exposed) can paste a token whose claim URL points at it. This path is untested
against real banks and is not supported; the hosted bridge is the default route
until a maintained self-hostable server exists.
