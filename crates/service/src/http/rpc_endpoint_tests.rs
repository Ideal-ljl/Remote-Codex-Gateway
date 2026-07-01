use super::{handle_parsed_rpc_request, validate_axum_headers};
use axum::http::HeaderMap;
use codexmanager_core::rpc::types::{
    JsonRpcMessage, JsonRpcNotification, JsonRpcRequest, JsonRpcResponse,
};

/// 函数 `panicking_rpc_handler_returns_structured_json_error`
///
/// 作者: gaohongshun
///
/// 时间: 2026-04-02
///
/// # 参数
/// 无
///
/// # 返回
/// 无
#[test]
fn panicking_rpc_handler_returns_structured_json_error() {
    let request = JsonRpcRequest {
        id: 7.into(),
        method: "account/usage/refresh".to_string(),
        params: None,
        trace: None,
    };

    let (body, success) = handle_parsed_rpc_request(request, |_req| {
        panic!("usage refresh boom");
    });

    assert!(!success);

    let parsed: serde_json::Value = serde_json::from_str(&body).expect("json body");
    assert_eq!(parsed.get("id").and_then(|value| value.as_u64()), Some(7));
    assert_eq!(
        parsed
            .get("error")
            .and_then(|value| value.get("message"))
            .and_then(|value| value.as_str()),
        Some("internal_error: usage refresh boom")
    );
    assert_eq!(
        parsed
            .get("error")
            .and_then(|value| value.get("code"))
            .and_then(|value| value.as_i64()),
        Some(-32603)
    );
}

/// 函数 `normal_rpc_handler_keeps_success_shape`
///
/// 作者: gaohongshun
///
/// 时间: 2026-04-02
///
/// # 参数
/// 无
///
/// # 返回
/// 无
#[test]
fn normal_rpc_handler_keeps_success_shape() {
    let request = JsonRpcRequest {
        id: 9.into(),
        method: "noop".to_string(),
        params: None,
        trace: None,
    };

    let (body, success) = handle_parsed_rpc_request(request, |req| {
        JsonRpcMessage::Response(JsonRpcResponse {
            id: req.id,
            result: serde_json::json!({ "ok": true }),
        })
    });

    assert!(success);
    let parsed: serde_json::Value = serde_json::from_str(&body).expect("json body");
    assert_eq!(parsed.get("id").and_then(|value| value.as_u64()), Some(9));
    assert_eq!(
        parsed
            .get("result")
            .and_then(|value| value.get("ok"))
            .and_then(|value| value.as_bool()),
        Some(true)
    );
}

/// 函数 `notification_handler_returns_empty_body`
///
/// 作者: gaohongshun
///
/// 时间: 2026-04-02
///
/// # 参数
/// 无
///
/// # 返回
/// 无
#[test]
fn notification_handler_returns_empty_body() {
    let request = JsonRpcRequest {
        id: 11.into(),
        method: "noop".to_string(),
        params: None,
        trace: None,
    };

    let (body, success) = handle_parsed_rpc_request(request, |_req| {
        JsonRpcMessage::Notification(JsonRpcNotification {
            method: "initialized".to_string(),
            params: None,
        })
    });

    assert!(success);
    assert!(body.is_empty());
}

fn valid_rpc_headers(origin: &str, host: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert("content-type", "application/json".parse().unwrap());
    headers.insert(
        "x-codexmanager-rpc-token",
        crate::rpc_auth_token().parse().unwrap(),
    );
    headers.insert("origin", origin.parse().unwrap());
    headers.insert("host", host.parse().unwrap());
    headers
}

#[test]
fn rpc_header_validation_allows_same_origin_dashboard_hosts() {
    let headers = valid_rpc_headers("http://gateway.example:48761", "gateway.example:48761");

    assert!(validate_axum_headers(&headers).is_none());
}

#[test]
fn rpc_header_validation_rejects_cross_origin_dashboard_hosts() {
    let headers = valid_rpc_headers("http://evil.example:48761", "gateway.example:48761");

    assert!(validate_axum_headers(&headers).is_some());
}
