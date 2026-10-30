"""A Jev-compatible decision model choosing one of the candidates it is given.

Every such model (TypeSafe's Jev, Baseten's elephant-1 and mammoth-1, a local
one) answers System One: POST /v1/systemone with typed questions, answered
with probabilities instead of text. The request and answer shapes are
TypeSafe's (typesafe-rs 0.1.0, src/types/question.rs and response.rs).

Configured from the environment with the names of Cua's OpenJev adapter
(https://github.com/trycua/cua/pull/3961), so an official one reads the same
settings: OPENJEV_BASE_URL (a base URL or the full /v1/systemone endpoint),
OPENJEV_API_KEY, OPENJEV_MODEL, OPENJEV_TIMEOUT_MS. OPENJEV_AUTH_SCHEME is
ours: TypeSafe takes "Bearer <key>", Baseten "Api-Key <key>".
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from typing import Any, Mapping
from urllib.parse import urlsplit

import httpx

ENDPOINT = "/v1/systemone"


@dataclass(frozen=True)
class Config:
    url: str
    model: str
    api_key: str
    auth_scheme: str
    timeout_s: float

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "Config":
        base = env.get("OPENJEV_BASE_URL", "").strip()
        parts = urlsplit(base)
        if parts.scheme not in {"https", "http"} or not parts.netloc:
            raise ValueError("OPENJEV_BASE_URL is not an http(s) URL")
        # As the OpenJev adapter: no credentials, query or fragment in the URL.
        if parts.username or parts.password or parts.query or parts.fragment:
            raise ValueError("OPENJEV_BASE_URL must be a plain URL")
        url = base.rstrip("/")
        if not url.endswith(ENDPOINT):
            url += ENDPOINT
        api_key = env.get("OPENJEV_API_KEY", "").strip()
        if api_key and parts.scheme != "https" and parts.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("an API key goes only over HTTPS")
        timeout_ms = int(env.get("OPENJEV_TIMEOUT_MS", "10000"))
        return cls(
            url=url,
            model=env.get("OPENJEV_MODEL", "").strip() or "openjev",
            api_key=api_key,
            auth_scheme=env.get("OPENJEV_AUTH_SCHEME", "").strip() or "Bearer",
            timeout_s=min(max(timeout_ms, 100), 60000) / 1000,
        )


@dataclass(frozen=True)
class Choice:
    selected_id: str
    confidence: float
    probabilities: dict[str, float]
    model: str


class DecisionError(RuntimeError):
    """The model could not be asked, or answered something unusable."""


def _probability(value: Any) -> float:
    number = float(value)
    if not math.isfinite(number) or not 0 <= number <= 1:
        raise DecisionError("the model returned a probability outside [0, 1]")
    return number


def ask(
    config: Config,
    *,
    state: Mapping[str, Any],
    questions: Mapping[str, tuple[str, Mapping[str, str]]],
    client: httpx.Client | None = None,
) -> dict[str, Choice]:
    """Choice questions, all in one request: name -> (instructions, criteria)."""
    if not questions or not all(criteria for _, criteria in questions.values()):
        raise DecisionError("no options to choose from")
    headers = {"Content-Type": "application/json"}
    if config.api_key:
        headers["Authorization"] = f"{config.auth_scheme} {config.api_key}"
    body = {
        "model": config.model,
        "state": dict(state),
        "questions": {
            name: {"type": "choice", "instructions": instructions, "criteria": dict(criteria)}
            for name, (instructions, criteria) in questions.items()
        },
    }
    own = client is None
    client = client or httpx.Client(timeout=config.timeout_s)
    try:
        response = client.post(config.url, json=body, headers=headers)
    except httpx.HTTPError as error:
        raise DecisionError(f"the decision model is unreachable ({type(error).__name__})") from None
    finally:
        if own:
            client.close()
    if response.status_code != 200:
        # The body may echo the request: only the status leaves here.
        raise DecisionError(f"the decision model answered HTTP {response.status_code}")
    try:
        data = response.json()
        answers = data["answers"]
    except (ValueError, KeyError, TypeError):
        raise DecisionError("the decision model's answer is not System One's") from None
    return {
        name: _choice(answers.get(name) if isinstance(answers, dict) else None, criteria,
                      str(data.get("model") or config.model))
        for name, (_, criteria) in questions.items()
    }


def _choice(answer: Any, criteria: Mapping[str, str], model: str) -> Choice:
    if not isinstance(answer, dict) or answer.get("type") != "choice":
        raise DecisionError("the decision model did not answer a choice question")
    selected = answer.get("choice")
    if selected not in criteria:
        raise DecisionError("the decision model chose an option it was not offered")
    probabilities = {}
    for option, value in (answer.get("probabilities") or {}).items():
        if option not in criteria:
            raise DecisionError("the decision model scored an option it was not offered")
        probabilities[option] = _probability(value)
    return Choice(
        selected_id=selected,
        confidence=_probability(answer.get("confidence", probabilities.get(selected, 0.0))),
        probabilities=probabilities,
        model=model,
    )


def choose(
    config: Config,
    *,
    instructions: str,
    state: Mapping[str, Any],
    criteria: Mapping[str, str],
    client: httpx.Client | None = None,
) -> Choice:
    """One choice question: which of ``criteria``'s IDs, given ``state``."""
    if not criteria:
        raise DecisionError("no candidates to choose from")
    return ask(config, state=state, questions={"next_action": (instructions, criteria)}, client=client)["next_action"]
