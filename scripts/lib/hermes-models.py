"""Hermes' own providers and models, for the bootstrap's model picker. Run
with Hermes' interpreter (its package's hermesVenv), with -I:

  hermes-models.py providers          id<TAB>label<TAB>key variable, one per line
                                      (no variable: a login, the ChatGPT subscription)
  hermes-models.py models <provider>  its model ids, one per line: the provider's
                                      live list (with its key in the environment, when
                                      it needs one), else the list Hermes ships
  hermes-models.py names              every provider name Hermes knows, aliases too,
                                      which another API must not take

Only the providers the bootstrap can set up: an API key, or the ChatGPT login
(its other logins and cloud accounts are left to `hermes model`). Local servers
and other OpenAI-compatible APIs go through "Another OpenAI-compatible API".
"""
import os
import shutil
import sys
import tempfile

# Hermes caches what it fetches in its home: a throwaway one, not ~/.hermes.
home = tempfile.mkdtemp(prefix="hermes-models.")
os.environ["HERMES_HOME"] = home


def providers():
    from hermes_cli.auth import PROVIDER_REGISTRY
    from hermes_cli.models import list_available_providers

    for p in list_available_providers():
        pid, config = p["id"], PROVIDER_REGISTRY.get(p["id"])
        if pid == "openai-codex":
            var = ""
        elif pid == "openrouter":  # Hermes resolves it apart, outside the registry
            var = "OPENROUTER_API_KEY"
        elif (
            config is not None
            and config.auth_type == "api_key"
            and config.api_key_env_vars
            and config.inference_base_url
            and "127.0.0.1" not in config.inference_base_url
            and "localhost" not in config.inference_base_url
        ):
            var = config.api_key_env_vars[0]
        else:
            continue
        print(f"{pid}\t{p['label']}\t{var}")


def models(provider):
    from hermes_cli.models import provider_model_ids

    for model in provider_model_ids(provider):
        print(model)


def names():
    from hermes_cli.models import list_available_providers

    for p in list_available_providers():
        for name in [p["id"], *p["aliases"]]:
            print(name)


try:
    command, *args = sys.argv[1:]
    {"providers": providers, "models": models, "names": names}[command](*args)
finally:
    shutil.rmtree(home, ignore_errors=True)
