use axum::response::Html;

const DASHBOARD_HTML: &str = include_str!("frontend_dashboard.html");

pub(crate) async fn handle_dashboard() -> Html<&'static str> {
    Html(DASHBOARD_HTML)
}
