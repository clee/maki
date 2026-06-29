use std::collections::HashMap;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use flume::Sender;
use serde::Deserialize;
use serde_json::Value;
use tracing::warn;

use crate::model::{Model, ModelEntry, ModelInfo, ModelPricing, lookup_entry, models_for_provider};
use crate::provider::{BoxFuture, Provider, ProviderKind};
use crate::{AgentError, Message, ProviderEvent, RequestOptions, StreamResponse};

use super::deepseek::DeepSeek;
use super::local::{LLAMACPP, LocalEndpoint, OLLAMA};
use super::mistral::Mistral;
use super::openai::OpenAi;
use super::openai_compat::{OpenAiCompatConfig, OpenAiCompatProvider};
use super::openrouter::OpenRouter;
use super::synthetic::Synthetic;
use super::tensorx::TensorX;
use super::zai::Zai;
use super::{ResolvedAuth, Timeouts};

const BASE_URL_ENV: &str = "APERTURE_BASE_URL";
const OVERRIDES_FILE: &str = "aperture-overrides.yml";
const PER_MILLION: f64 = 1_000_000.0;

static CONFIG: OpenAiCompatConfig = OpenAiCompatConfig {
    api_key_env: BASE_URL_ENV,
    base_url: "",
    max_tokens_field: "max_tokens",
    include_stream_usage: true,
    provider_name: "Aperture",
};

inventory::submit!(maki_config::providers::BuiltInProvider {
    slug: "aperture",
    display_name: "Aperture",
    protocol: maki_config::providers::Protocol::Openai,
    default_base_url: "",
    default_api_key_env: BASE_URL_ENV,
    default_model: "",
    plans: None,
    login_url: None,
    needs_url: true,
});

pub(crate) fn models() -> &'static [ModelEntry] {
    &[]
}

#[derive(Deserialize, Default, Clone)]
struct OverrideFields {
    #[serde(default)]
    context_window: Option<u32>,
    #[serde(default)]
    max_output_tokens: Option<u32>,
    /// Remap this model/provider to a native provider (e.g. an opaque gateway
    /// vendor `ikora-openai` that is really a `llama-cpp` server). Must name an
    /// OpenAI-compatible provider; validated once at load.
    #[serde(default)]
    base: Option<String>,
}

#[derive(Deserialize, Default)]
struct ProviderOverride {
    #[serde(flatten)]
    default: OverrideFields,
    #[serde(default)]
    models: HashMap<String, OverrideFields>,
}

type Overrides = HashMap<String, ProviderOverride>;

fn load_overrides() -> Overrides {
    let path = match maki_storage::paths::config_dir() {
        Ok(d) => d.join(OVERRIDES_FILE),
        Err(_) => return Overrides::default(),
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return Overrides::default(),
    };
    let overrides = match serde_yaml::from_str::<Overrides>(&text) {
        Ok(o) => o,
        Err(e) => {
            warn!(path = %path.display(), error = %e, "failed to parse aperture-overrides.yml, ignoring");
            return Overrides::default();
        }
    };
    validate_overrides(&overrides);
    overrides
}

/// Warn once about `base` values that don't name an OpenAI-compatible provider,
/// so a typo doesn't silently fall through to the generic path.
fn validate_overrides(overrides: &Overrides) {
    for (prov, po) in overrides {
        if let Some(b) = &po.default.base
            && parse_compat_base(b).is_none()
        {
            warn!(
                provider = prov,
                base = b,
                "base is not an OpenAI-compatible provider, ignoring"
            );
        }
        for (mid, m) in &po.models {
            if let Some(b) = &m.base
                && parse_compat_base(b).is_none()
            {
                warn!(
                    provider = prov,
                    model = mid,
                    base = b,
                    "base is not an OpenAI-compatible provider, ignoring"
                );
            }
        }
    }
}

/// Model-level fields win over provider-level defaults, field by field.
fn merged_override(overrides: &Overrides, provider_id: &str, model_id: &str) -> OverrideFields {
    let Some(po) = overrides.get(provider_id) else {
        return OverrideFields::default();
    };
    let mut out = po.default.clone();
    if let Some(m) = po.models.get(model_id) {
        if m.context_window.is_some() {
            out.context_window = m.context_window;
        }
        if m.max_output_tokens.is_some() {
            out.max_output_tokens = m.max_output_tokens;
        }
        if m.base.is_some() {
            out.base = m.base.clone();
        }
    }
    out
}

/// OpenAI-compatible providers Aperture's gateway can actually serve.
/// Anthropic/Google/Copilot use wire formats (messages API / Gemini / Copilot
/// chat) that the OpenAI-compat gateway does not proxy.
fn compat_kind(kind: ProviderKind) -> Option<ProviderKind> {
    match kind {
        ProviderKind::OpenAi
        | ProviderKind::Ollama
        | ProviderKind::LlamaCpp
        | ProviderKind::Mistral
        | ProviderKind::Zai
        | ProviderKind::DeepSeek
        | ProviderKind::OpenRouter
        | ProviderKind::Synthetic
        | ProviderKind::TensorX => Some(kind),
        _ => None,
    }
}

fn parse_compat_base(s: &str) -> Option<ProviderKind> {
    ProviderKind::from_str(s).ok().and_then(compat_kind)
}

/// Resolve the native provider an Aperture model should stream through. A
/// model-level override `base` wins, then the provider-level override `base`,
/// then the provider segment of the id if it itself names a known
/// OpenAI-compatible provider. Lets a user remap an opaque gateway vendor
/// (e.g. `ikora-openai`) to a real native provider (e.g. `llama-cpp`). `None`
/// falls through to the generic OpenAI-compat path.
fn routed_kind(provider_id: &str, overrides: &Overrides, model_id: &str) -> Option<ProviderKind> {
    let merged = merged_override(overrides, provider_id, model_id);
    [merged.base.as_deref(), Some(provider_id)]
        .into_iter()
        .flatten()
        .find_map(parse_compat_base)
}

fn build_routed_provider(
    kind: ProviderKind,
    auth: Arc<Mutex<ResolvedAuth>>,
    timeouts: Timeouts,
    system_prefix: Option<String>,
) -> Box<dyn Provider> {
    match kind {
        ProviderKind::OpenAi => {
            Box::new(OpenAi::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        ProviderKind::Ollama => Box::new(
            LocalEndpoint::with_auth(&OLLAMA, auth, timeouts).with_system_prefix(system_prefix),
        ),
        ProviderKind::LlamaCpp => Box::new(
            LocalEndpoint::with_auth(&LLAMACPP, auth, timeouts).with_system_prefix(system_prefix),
        ),
        ProviderKind::Mistral => {
            Box::new(Mistral::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        ProviderKind::Zai => {
            Box::new(Zai::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        ProviderKind::DeepSeek => {
            Box::new(DeepSeek::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        ProviderKind::OpenRouter => {
            Box::new(OpenRouter::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        ProviderKind::Synthetic => {
            Box::new(Synthetic::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        ProviderKind::TensorX => {
            Box::new(TensorX::with_auth(auth, timeouts).with_system_prefix(system_prefix))
        }
        _ => unreachable!("routed_kind only returns the variants matched above"),
    }
}

pub struct Aperture {
    compat: OpenAiCompatProvider,
    auth: Arc<Mutex<ResolvedAuth>>,
    timeouts: Timeouts,
    system_prefix: Option<String>,
    overrides: Overrides,
}

impl Aperture {
    pub fn new(timeouts: Timeouts) -> Result<Self, AgentError> {
        let base_url = resolve_base_url()?;
        let auth = Arc::new(Mutex::new(ResolvedAuth {
            base_url: Some(base_url),
            headers: Vec::new(),
        }));
        Ok(Self {
            compat: OpenAiCompatProvider::new(&CONFIG, timeouts),
            auth,
            timeouts,
            system_prefix: None,
            overrides: load_overrides(),
        })
    }

    pub(crate) fn with_auth(auth: Arc<Mutex<ResolvedAuth>>, timeouts: Timeouts) -> Self {
        Self {
            compat: OpenAiCompatProvider::new(&CONFIG, timeouts),
            auth,
            timeouts,
            system_prefix: None,
            overrides: load_overrides(),
        }
    }

    pub(crate) fn with_system_prefix(mut self, prefix: Option<String>) -> Self {
        self.system_prefix = prefix.filter(|s| !s.is_empty());
        self
    }
}

fn resolve_base_url() -> Result<String, AgentError> {
    if let Ok(url) = std::env::var(BASE_URL_ENV)
        && !url.trim().is_empty()
    {
        return Ok(trim_slash(url));
    }
    if let Some(url) = maki_config::providers::ProvidersConfig::load()
        .get("aperture")
        .and_then(|d| d.base_url.clone())
        .filter(|u| !u.trim().is_empty())
    {
        return Ok(trim_slash(url));
    }
    Err(AgentError::Config {
        message: format!("{BASE_URL_ENV} not set"),
    })
}

fn trim_slash(url: String) -> String {
    url.trim().trim_end_matches('/').to_string()
}

fn price_per_m(field: Option<&Value>) -> f64 {
    field
        .and_then(|v| v.as_str())
        .and_then(|s| s.parse::<f64>().ok())
        .map(|n| n * PER_MILLION)
        .unwrap_or(0.0)
}

fn parse_models(body: &Value, overrides: &Overrides) -> Vec<ModelInfo> {
    body["data"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let id = m["id"].as_str()?;
                    let provider_id = m["metadata"]["provider"]["id"].as_str().unwrap_or("");
                    let full_id = if provider_id.is_empty() {
                        id.to_string()
                    } else {
                        format!("{provider_id}/{id}")
                    };
                    let pricing = m["pricing"].as_object().map(|p| ModelPricing {
                        input: price_per_m(p.get("input")),
                        output: price_per_m(p.get("output")),
                        cache_read: price_per_m(p.get("input_cache_read")),
                        cache_write: 0.0,
                        fast: None,
                    });
                    let mut info = ModelInfo {
                        id: full_id,
                        context_window: None,
                        max_output_tokens: None,
                        pricing,
                    };
                    if !provider_id.is_empty() {
                        let ov = merged_override(overrides, provider_id, id);
                        if let Some(cw) = ov.context_window {
                            info.context_window = Some(cw);
                        }
                        if let Some(mo) = ov.max_output_tokens {
                            info.max_output_tokens = Some(mo);
                        }
                    }
                    Some(info)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Reconcile a model's metadata against its routed native provider's static
/// table, then layer user overrides on top. The static table is the baseline
/// (so `aperture/zai/glm-5.2` picks up Zai's real `context_window` without
/// being hand-duplicated in overrides.yml); explicit overrides still win.
fn apply_adjustments(model: &mut Model, overrides: &Overrides) {
    let Some((provider_id, model_id)) = model.id.split_once('/') else {
        return;
    };
    if let Some(kind) = routed_kind(provider_id, overrides, model_id) {
        model.family = kind.family();
        model.supports_thinking_override = Some(kind.supports_thinking());
        if let Ok(entry) = lookup_entry(models_for_provider(kind), model_id) {
            model.context_window = entry.context_window;
            model.max_output_tokens = entry.max_output_tokens;
        }
    }
    let ov = merged_override(overrides, provider_id, model_id);
    if let Some(cw) = ov.context_window {
        model.context_window = cw;
    }
    if let Some(mo) = ov.max_output_tokens {
        model.max_output_tokens = mo;
    }
}

impl Provider for Aperture {
    fn stream_message<'a>(
        &'a self,
        model: &'a Model,
        messages: &'a [Message],
        system: &'a str,
        tools: &'a Value,
        event_tx: &'a Sender<ProviderEvent>,
        opts: RequestOptions,
        session_id: Option<&'a str>,
    ) -> BoxFuture<'a, Result<StreamResponse, AgentError>> {
        Box::pin(async move {
            if let Some((provider_id, model_id)) = model.id.split_once('/')
                && let Some(kind) = routed_kind(provider_id, &self.overrides, model_id)
            {
                let provider = build_routed_provider(
                    kind,
                    self.auth.clone(),
                    self.timeouts,
                    self.system_prefix.clone(),
                );
                return provider
                    .stream_message(model, messages, system, tools, event_tx, opts, session_id)
                    .await;
            }
            let auth = self.auth.lock().unwrap().clone();
            let mut buf = String::new();
            let system = super::with_prefix(&self.system_prefix, system, &mut buf);
            let body = self.compat.build_body(model, messages, system, tools);
            self.compat
                .do_stream(model, &[], &body, event_tx, &auth)
                .await
        })
    }

    fn list_models(&self) -> BoxFuture<'_, Result<Vec<ModelInfo>, AgentError>> {
        Box::pin(async move {
            let auth = self.auth.lock().unwrap().clone();
            let base = auth.base_url.as_deref().unwrap_or("");
            let text = self
                .compat
                .get_text(&auth, &format!("{base}/v1/models"))
                .await?;
            let body: Value = serde_json::from_str(&text)?;
            Ok(parse_models(&body, &self.overrides))
        })
    }

    fn adjust_model(&self, model: &mut Model) {
        apply_adjustments(model, &self.overrides);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ModelFamily;
    use serde_json::json;
    use test_case::test_case;

    #[test_case("zai", Some(ProviderKind::Zai) ; "known_zai")]
    #[test_case("synthetic", Some(ProviderKind::Synthetic) ; "known_synthetic")]
    #[test_case("openai", Some(ProviderKind::OpenAi) ; "known_openai")]
    #[test_case("llama-cpp", Some(ProviderKind::LlamaCpp) ; "known_llama_cpp")]
    #[test_case("ikora-openai", None ; "unknown_vendor_no_override")]
    #[test_case("anthropic", None ; "non_compat_anthropic")]
    #[test_case("google", None ; "non_compat_google")]
    #[test_case("copilot", None ; "copilot_excluded")]
    #[test_case("aperture", None ; "aperture_no_recurse")]
    fn routed_kind_without_overrides(provider_id: &str, expected: Option<ProviderKind>) {
        assert_eq!(routed_kind(provider_id, &Overrides::new(), "any"), expected);
    }

    #[test]
    fn routed_kind_override_remaps_unknown_vendor() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "ikora-openai".into(),
            ProviderOverride {
                default: OverrideFields {
                    base: Some("llama-cpp".into()),
                    ..Default::default()
                },
                ..Default::default()
            },
        );
        assert_eq!(
            routed_kind("ikora-openai", &overrides, "gemma4"),
            Some(ProviderKind::LlamaCpp)
        );
    }

    #[test]
    fn routed_kind_model_base_wins_over_provider_base() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "ikora-openai".into(),
            ProviderOverride {
                default: OverrideFields {
                    base: Some("openai".into()),
                    ..Default::default()
                },
                models: HashMap::from([(
                    "special".into(),
                    OverrideFields {
                        base: Some("llama-cpp".into()),
                        ..Default::default()
                    },
                )]),
            },
        );
        assert_eq!(
            routed_kind("ikora-openai", &overrides, "special"),
            Some(ProviderKind::LlamaCpp)
        );
        assert_eq!(
            routed_kind("ikora-openai", &overrides, "other"),
            Some(ProviderKind::OpenAi)
        );
    }

    #[test]
    fn routed_kind_invalid_override_falls_back_to_provider_id() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "zai".into(),
            ProviderOverride {
                default: OverrideFields {
                    base: Some("not-a-real-provider".into()),
                    ..Default::default()
                },
                ..Default::default()
            },
        );
        assert_eq!(
            routed_kind("zai", &overrides, "glm-5.2"),
            Some(ProviderKind::Zai)
        );
    }

    #[test]
    fn merged_override_model_wins_over_provider_default() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "zai".into(),
            ProviderOverride {
                default: OverrideFields {
                    context_window: Some(128_000),
                    max_output_tokens: Some(8_192),
                    ..Default::default()
                },
                models: HashMap::from([(
                    "glm-5.2".into(),
                    OverrideFields {
                        context_window: Some(200_000),
                        ..Default::default()
                    },
                )]),
            },
        );
        let ov = merged_override(&overrides, "zai", "glm-5.2");
        assert_eq!(ov.context_window, Some(200_000));
        assert_eq!(ov.max_output_tokens, Some(8_192));
    }

    #[test]
    fn merged_override_unknown_provider_is_empty() {
        let overrides = Overrides::new();
        let ov = merged_override(&overrides, "nobody", "x");
        assert!(ov.context_window.is_none());
        assert!(ov.max_output_tokens.is_none());
        assert!(ov.base.is_none());
    }

    #[test]
    fn parse_models_prefixes_provider_pricing_and_overrides() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "ollama".into(),
            ProviderOverride {
                default: OverrideFields::default(),
                models: HashMap::from([(
                    "qwen3.6".into(),
                    OverrideFields {
                        context_window: Some(65_536),
                        ..Default::default()
                    },
                )]),
            },
        );
        let body = json!({
            "object": "list",
            "data": [
                {"id": "qwen3.6", "metadata": {"provider": {"id": "ollama"}}, "pricing": {"input": "0.000001", "output": "0.000002", "input_cache_read": "0.0000001"}},
                {"id": "gemma4", "metadata": {"provider": {"id": "ikora"}}},
                {"id": "raw-model"}
            ]
        });
        let models = parse_models(&body, &overrides);
        assert_eq!(models.len(), 3);
        assert_eq!(models[0].id, "ollama/qwen3.6");
        assert_eq!(models[0].context_window, Some(65_536));
        assert!(models[0].max_output_tokens.is_none());
        let p = models[0].pricing.as_ref().unwrap();
        assert!((p.input - 1.0).abs() < 1e-9);
        assert!((p.output - 2.0).abs() < 1e-9);
        assert!((p.cache_read - 0.1).abs() < 1e-9);
        assert_eq!(models[1].id, "ikora/gemma4");
        assert!(models[1].pricing.is_none());
        assert_eq!(models[2].id, "raw-model");
    }

    #[test]
    fn parse_models_handles_missing_data() {
        assert!(parse_models(&json!({}), &Overrides::new()).is_empty());
        assert!(parse_models(&json!({"data": []}), &Overrides::new()).is_empty());
    }

    #[test]
    fn apply_adjustments_uses_routed_provider_static_table() {
        let mut model = Model::from_spec("aperture/zai/glm-5.2").unwrap();
        assert_eq!(
            model.context_window,
            ProviderKind::Aperture.fallback_context_window()
        );
        apply_adjustments(&mut model, &Overrides::new());
        assert_eq!(model.context_window, 1_000_000);
        assert_eq!(model.max_output_tokens, 131_072);
        assert_eq!(model.family, ModelFamily::Glm);
    }

    #[test]
    fn apply_adjustments_override_wins_over_static_table() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "zai".into(),
            ProviderOverride {
                default: OverrideFields {
                    context_window: Some(200_000),
                    ..Default::default()
                },
                ..Default::default()
            },
        );
        let mut model = Model::from_spec("aperture/zai/glm-5.2").unwrap();
        apply_adjustments(&mut model, &overrides);
        assert_eq!(model.context_window, 200_000);
        assert_eq!(model.max_output_tokens, 131_072);
    }

    #[test]
    fn apply_adjustments_no_route_leaves_model_untouched() {
        let mut model = Model::from_spec("aperture/ikora-openai/gemma4").unwrap();
        let before = model.clone();
        apply_adjustments(&mut model, &Overrides::new());
        assert_eq!(model.context_window, before.context_window);
        assert_eq!(model.max_output_tokens, before.max_output_tokens);
        assert!(model.supports_thinking_override.is_none());
        assert!(!model.supports_thinking());
    }

    #[test_case("aperture/openai/gpt-test", ProviderKind::OpenAi ; "routed_thinking_capable")]
    #[test_case("aperture/ollama/qwen3", ProviderKind::Ollama ; "routed_non_thinking")]
    #[test_case("aperture/zai/glm-5.2", ProviderKind::Zai ; "routed_zai")]
    fn apply_adjustments_thinking_follows_routed_kind(spec: &str, kind: ProviderKind) {
        let mut model = Model::from_spec(spec).unwrap();
        assert!(model.supports_thinking_override.is_none());
        apply_adjustments(&mut model, &Overrides::new());
        assert_eq!(
            model.supports_thinking_override,
            Some(kind.supports_thinking())
        );
        assert_eq!(model.supports_thinking(), kind.supports_thinking());
    }

    #[test]
    fn apply_adjustments_thinking_via_base_override() {
        let mut overrides = Overrides::new();
        overrides.insert(
            "ikora-openai".into(),
            ProviderOverride {
                default: OverrideFields {
                    base: Some("llama-cpp".into()),
                    ..Default::default()
                },
                ..Default::default()
            },
        );
        let mut model = Model::from_spec("aperture/ikora-openai/gemma4").unwrap();
        apply_adjustments(&mut model, &overrides);
        assert_eq!(
            model.supports_thinking_override,
            Some(ProviderKind::LlamaCpp.supports_thinking())
        );
    }

    #[test]
    fn overrides_roundtrip_from_yaml() {
        let yaml = "\
ikora-openai:
  base: llama-cpp
zai:
  context_window: 128000
  max_output_tokens: 8192
  models:
    glm-5.2:
      context_window: 200000
";
        let overrides: Overrides = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(
            routed_kind("ikora-openai", &overrides, "gemma4"),
            Some(ProviderKind::LlamaCpp)
        );
        let ov = merged_override(&overrides, "zai", "glm-5.2");
        assert_eq!(ov.context_window, Some(200_000));
        assert_eq!(ov.max_output_tokens, Some(8_192));
        let ov2 = merged_override(&overrides, "zai", "other");
        assert_eq!(ov2.context_window, Some(128_000));
    }
}
