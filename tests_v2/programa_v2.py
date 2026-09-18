"""GENERATED FILE — do not edit by hand.

Source of truth: contracts/v2/methods.json
Regenerate with: python3 scripts/gen-v2-contract.py
Verify with:      scripts/check-v2-contract.sh
"""

from typing import Any, Dict, Optional

from cmux import cmux, cmuxError


class ProgramaV2Error(cmuxError):
    """Raised by ProgramaV2Client for client-side param validation failures."""


class ProgramaV2Client:
    """Generated typed v2 client: one method per contract entry.

    Thin wrapper over tests_v2.cmux.cmux — it owns (or is given) the transport
    connection and framing, this class only adds per-method required-param
    validation and a method name per contract entry."""

    def __init__(self, socket_path: Optional[str] = None, client: Optional[cmux] = None):
        self._client = client if client is not None else cmux(socket_path)
        self._owns_client = client is None

    def connect(self) -> None:
        self._client.connect()

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:
        """Escape hatch for a method not (yet) in the generated set below."""
        return self._client._call(method, params)

    def agent_detection_classify(self, agent: Optional[Any] = None, lines: Optional[Any] = None, scrollback: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (classify)."""
        params: Dict[str, Any] = {}
        if agent is not None:
            params["agent"] = agent
        if lines is not None:
            params["lines"] = lines
        if scrollback is not None:
            params["scrollback"] = scrollback
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("agent.detection.classify", params)

    def agent_detection_list(self, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (list)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("agent.detection.list", params)

    def agent_event(self, event_type: Optional[Any] = None, item_id: Optional[Any] = None, label: Optional[Any] = None, pid: Optional[Any] = None, provider: Optional[Any] = None, resolution: Optional[Any] = None, session_id: Optional[Any] = None, surface_id: Optional[Any] = None, turn_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Normalized agent lifecycle event from a provider hook (docs/plans/agent-events.md)."""
        params: Dict[str, Any] = {}
        if event_type is not None:
            params["event_type"] = event_type
        if item_id is not None:
            params["item_id"] = item_id
        if label is not None:
            params["label"] = label
        if pid is not None:
            params["pid"] = pid
        if provider is not None:
            params["provider"] = provider
        if resolution is not None:
            params["resolution"] = resolution
        if session_id is not None:
            params["session_id"] = session_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if turn_id is not None:
            params["turn_id"] = turn_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("agent.event requires 'workspace_id'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("agent.event requires 'surface_id'")
        if params.get("event_type") is None:
            raise ProgramaV2Error("agent.event requires 'event_type'")
        return self._client._call("agent.event", params)

    def agent_needs_input(self, body: Optional[Any] = None, kind: Optional[Any] = None, pid: Optional[Any] = None, provider: Optional[Any] = None, session_id: Optional[Any] = None, subtitle: Optional[Any] = None, surface_id: Optional[Any] = None, title: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Atomically reports a surface as blocked on user input and posts the matching notification (docs/plans/agent-state-unification.md)."""
        params: Dict[str, Any] = {}
        if body is not None:
            params["body"] = body
        if kind is not None:
            params["kind"] = kind
        if pid is not None:
            params["pid"] = pid
        if provider is not None:
            params["provider"] = provider
        if session_id is not None:
            params["session_id"] = session_id
        if subtitle is not None:
            params["subtitle"] = subtitle
        if surface_id is not None:
            params["surface_id"] = surface_id
        if title is not None:
            params["title"] = title
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("agent.needs_input requires 'workspace_id'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("agent.needs_input requires 'surface_id'")
        return self._client._call("agent.needs_input", params)

    def agent_prompt(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, text: Optional[Any] = None, timeout: Optional[Any] = None, timeout_ms: Optional[Any] = None, window_id: Optional[Any] = None, working_grace_ms: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (prompt)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if text is not None:
            params["text"] = text
        if timeout is not None:
            params["timeout"] = timeout
        if timeout_ms is not None:
            params["timeout_ms"] = timeout_ms
        if window_id is not None:
            params["window_id"] = window_id
        if working_grace_ms is not None:
            params["working_grace_ms"] = working_grace_ms
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("text") is None:
            raise ProgramaV2Error("agent.prompt requires 'text'")
        return self._client._call("agent.prompt", params)

    def agent_spawn(self, initial_env: Optional[Any] = None, path: Optional[Any] = None, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (spawn)."""
        params: Dict[str, Any] = {}
        if initial_env is not None:
            params["initial_env"] = initial_env
        if path is not None:
            params["path"] = path
        params.update(extra_params)
        if params.get("initial_env") is None:
            raise ProgramaV2Error("agent.spawn requires 'initial_env'")
        return self._client._call("agent.spawn", params)

    def agent_task_finish(self, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (finish)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("agent.task.finish", params)

    def agent_task_finish_session(self, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (finish session)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("agent.task.finish_session", params)

    def agent_task_list(self, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (list)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("agent.task.list", params)

    def agent_task_start(self, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (start)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("agent.task.start", params)

    def agent_task_update(self, **extra_params: Any) -> Any:
        """Agent task lifecycle, spawning, and prompt delivery. (update)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("agent.task.update", params)

    def app_browsers(self, **extra_params: Any) -> Any:
        """App-level focus/activation and browser discovery. (browsers)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("app.browsers", params)

    def app_focus_override_set(self, focused: Optional[Any] = None, state: Optional[Any] = None, **extra_params: Any) -> Any:
        """App-level focus/activation and browser discovery. (set)."""
        params: Dict[str, Any] = {}
        if focused is not None:
            params["focused"] = focused
        if state is not None:
            params["state"] = state
        params.update(extra_params)
        return self._client._call("app.focus_override.set", params)

    def app_reload_config(self, **extra_params: Any) -> Any:
        """App-level focus/activation and browser discovery. (reload config)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("app.reload_config", params)

    def app_simulate_active(self, **extra_params: Any) -> Any:
        """App-level focus/activation and browser discovery. (simulate active)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("app.simulate_active", params)

    def auth_login(self, **extra_params: Any) -> Any:
        """Password-mode authentication handshake. (login)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("auth.login", params)

    def browser_addinitscript(self, content: Optional[Any] = None, script: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (addinitscript)."""
        params: Dict[str, Any] = {}
        if content is not None:
            params["content"] = content
        if script is not None:
            params["script"] = script
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("content", "script",)):
            raise ProgramaV2Error("browser.addinitscript requires one of: content, script")
        return self._client._call("browser.addinitscript", params)

    def browser_addscript(self, content: Optional[Any] = None, script: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (addscript)."""
        params: Dict[str, Any] = {}
        if content is not None:
            params["content"] = content
        if script is not None:
            params["script"] = script
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("content", "script",)):
            raise ProgramaV2Error("browser.addscript requires one of: content, script")
        return self._client._call("browser.addscript", params)

    def browser_addstyle(self, content: Optional[Any] = None, css: Optional[Any] = None, style: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (addstyle)."""
        params: Dict[str, Any] = {}
        if content is not None:
            params["content"] = content
        if css is not None:
            params["css"] = css
        if style is not None:
            params["style"] = style
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("content", "css", "style",)):
            raise ProgramaV2Error("browser.addstyle requires one of: content, css, style")
        return self._client._call("browser.addstyle", params)

    def browser_back(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (back)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.back", params)

    def browser_check(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (check)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.check", params)

    def browser_click(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (click)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.click", params)

    def browser_console_clear(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (clear)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.console.clear", params)

    def browser_console_list(self, clear: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (list)."""
        params: Dict[str, Any] = {}
        if clear is not None:
            params["clear"] = clear
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.console.list", params)

    def browser_cookies_clear(self, all: Optional[Any] = None, domain: Optional[Any] = None, name: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (clear)."""
        params: Dict[str, Any] = {}
        if all is not None:
            params["all"] = all
        if domain is not None:
            params["domain"] = domain
        if name is not None:
            params["name"] = name
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.cookies.clear", params)

    def browser_cookies_get(self, domain: Optional[Any] = None, name: Optional[Any] = None, path: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (get)."""
        params: Dict[str, Any] = {}
        if domain is not None:
            params["domain"] = domain
        if name is not None:
            params["name"] = name
        if path is not None:
            params["path"] = path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.cookies.get", params)

    def browser_cookies_set(self, cookies: Optional[Any] = None, domain: Optional[Any] = None, expires: Optional[Any] = None, name: Optional[Any] = None, path: Optional[Any] = None, secure: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, url: Optional[Any] = None, value: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (set)."""
        params: Dict[str, Any] = {}
        if cookies is not None:
            params["cookies"] = cookies
        if domain is not None:
            params["domain"] = domain
        if expires is not None:
            params["expires"] = expires
        if name is not None:
            params["name"] = name
        if path is not None:
            params["path"] = path
        if secure is not None:
            params["secure"] = secure
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if url is not None:
            params["url"] = url
        if value is not None:
            params["value"] = value
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.cookies.set", params)

    def browser_dblclick(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (dblclick)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.dblclick", params)

    def browser_design_mode_toggle(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (toggle)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.design_mode.toggle", params)

    def browser_dialog_accept(self, prompt_text: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, text: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (accept)."""
        params: Dict[str, Any] = {}
        if prompt_text is not None:
            params["prompt_text"] = prompt_text
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if text is not None:
            params["text"] = text
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.dialog.accept", params)

    def browser_dialog_dismiss(self, prompt_text: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, text: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (dismiss)."""
        params: Dict[str, Any] = {}
        if prompt_text is not None:
            params["prompt_text"] = prompt_text
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if text is not None:
            params["text"] = text
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.dialog.dismiss", params)

    def browser_download_wait(self, _test_pending_marker_path: Optional[Any] = None, path: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, timeout: Optional[Any] = None, timeout_ms: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (wait)."""
        params: Dict[str, Any] = {}
        if _test_pending_marker_path is not None:
            params["_test_pending_marker_path"] = _test_pending_marker_path
        if path is not None:
            params["path"] = path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if timeout is not None:
            params["timeout"] = timeout
        if timeout_ms is not None:
            params["timeout_ms"] = timeout_ms
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("path") is None:
            raise ProgramaV2Error("browser.download.wait requires 'path'")
        return self._client._call("browser.download.wait", params)

    def browser_errors_list(self, clear: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (list)."""
        params: Dict[str, Any] = {}
        if clear is not None:
            params["clear"] = clear
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.errors.list", params)

    def browser_eval(self, script: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (eval)."""
        params: Dict[str, Any] = {}
        if script is not None:
            params["script"] = script
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("script") is None:
            raise ProgramaV2Error("browser.eval requires 'script'")
        return self._client._call("browser.eval", params)

    def browser_fill(self, text: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (fill)."""
        params: Dict[str, Any] = {}
        if text is not None:
            params["text"] = text
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("text", "value",)):
            raise ProgramaV2Error("browser.fill requires one of: text, value")
        return self._client._call("browser.fill", params)

    def browser_find_alt(self, alt: Optional[Any] = None, exact: Optional[Any] = None, text: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (alt)."""
        params: Dict[str, Any] = {}
        if alt is not None:
            params["alt"] = alt
        if exact is not None:
            params["exact"] = exact
        if text is not None:
            params["text"] = text
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("alt", "text", "value",)):
            raise ProgramaV2Error("browser.find.alt requires one of: alt, text, value")
        return self._client._call("browser.find.alt", params)

    def browser_find_first(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (first)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.find.first", params)

    def browser_find_label(self, exact: Optional[Any] = None, label: Optional[Any] = None, text: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (label)."""
        params: Dict[str, Any] = {}
        if exact is not None:
            params["exact"] = exact
        if label is not None:
            params["label"] = label
        if text is not None:
            params["text"] = text
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("label", "text", "value",)):
            raise ProgramaV2Error("browser.find.label requires one of: label, text, value")
        return self._client._call("browser.find.label", params)

    def browser_find_last(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (last)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.find.last", params)

    def browser_find_nth(self, index: Optional[Any] = None, nth: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (nth)."""
        params: Dict[str, Any] = {}
        if index is not None:
            params["index"] = index
        if nth is not None:
            params["nth"] = nth
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("index", "nth",)):
            raise ProgramaV2Error("browser.find.nth requires one of: index, nth")
        return self._client._call("browser.find.nth", params)

    def browser_find_placeholder(self, exact: Optional[Any] = None, placeholder: Optional[Any] = None, text: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (placeholder)."""
        params: Dict[str, Any] = {}
        if exact is not None:
            params["exact"] = exact
        if placeholder is not None:
            params["placeholder"] = placeholder
        if text is not None:
            params["text"] = text
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("placeholder", "text", "value",)):
            raise ProgramaV2Error("browser.find.placeholder requires one of: placeholder, text, value")
        return self._client._call("browser.find.placeholder", params)

    def browser_find_role(self, exact: Optional[Any] = None, name: Optional[Any] = None, role: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (role)."""
        params: Dict[str, Any] = {}
        if exact is not None:
            params["exact"] = exact
        if name is not None:
            params["name"] = name
        if role is not None:
            params["role"] = role
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("role", "value",)):
            raise ProgramaV2Error("browser.find.role requires one of: role, value")
        return self._client._call("browser.find.role", params)

    def browser_find_testid(self, test_id: Optional[Any] = None, testid: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (testid)."""
        params: Dict[str, Any] = {}
        if test_id is not None:
            params["test_id"] = test_id
        if testid is not None:
            params["testid"] = testid
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("test_id", "testid", "value",)):
            raise ProgramaV2Error("browser.find.testid requires one of: test_id, testid, value")
        return self._client._call("browser.find.testid", params)

    def browser_find_text(self, exact: Optional[Any] = None, text: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (text)."""
        params: Dict[str, Any] = {}
        if exact is not None:
            params["exact"] = exact
        if text is not None:
            params["text"] = text
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("text", "value",)):
            raise ProgramaV2Error("browser.find.text requires one of: text, value")
        return self._client._call("browser.find.text", params)

    def browser_find_title(self, exact: Optional[Any] = None, text: Optional[Any] = None, title: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (title)."""
        params: Dict[str, Any] = {}
        if exact is not None:
            params["exact"] = exact
        if text is not None:
            params["text"] = text
        if title is not None:
            params["title"] = title
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("text", "title", "value",)):
            raise ProgramaV2Error("browser.find.title requires one of: text, title, value")
        return self._client._call("browser.find.title", params)

    def browser_focus(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (focus)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.focus", params)

    def browser_focus_webview(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (focus webview)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("browser.focus_webview requires 'surface_id'")
        return self._client._call("browser.focus_webview", params)

    def browser_forward(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (forward)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.forward", params)

    def browser_frame_main(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (main)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.frame.main", params)

    def browser_frame_select(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (select)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.frame.select", params)

    def browser_geolocation_set(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (set)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.geolocation.set", params)

    def browser_get_attr(self, attr: Optional[Any] = None, name: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (attr)."""
        params: Dict[str, Any] = {}
        if attr is not None:
            params["attr"] = attr
        if name is not None:
            params["name"] = name
        params.update(extra_params)
        if not any(params.get(k) is not None for k in ("attr", "name",)):
            raise ProgramaV2Error("browser.get.attr requires one of: attr, name")
        return self._client._call("browser.get.attr", params)

    def browser_get_box(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (box)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.get.box", params)

    def browser_get_count(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (count)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.get.count", params)

    def browser_get_html(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (html)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.get.html", params)

    def browser_get_styles(self, property: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (styles)."""
        params: Dict[str, Any] = {}
        if property is not None:
            params["property"] = property
        params.update(extra_params)
        return self._client._call("browser.get.styles", params)

    def browser_get_text(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (text)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.get.text", params)

    def browser_get_title(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (title)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.get.title", params)

    def browser_get_value(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (value)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.get.value", params)

    def browser_highlight(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (highlight)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.highlight", params)

    def browser_hover(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (hover)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.hover", params)

    def browser_input_keyboard(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (input keyboard)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.input_keyboard", params)

    def browser_input_mouse(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (input mouse)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.input_mouse", params)

    def browser_input_touch(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (input touch)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.input_touch", params)

    def browser_is_checked(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (checked)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.is.checked", params)

    def browser_is_enabled(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (enabled)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.is.enabled", params)

    def browser_is_visible(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (visible)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.is.visible", params)

    def browser_is_webview_focused(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (is webview focused)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("browser.is_webview_focused requires 'surface_id'")
        return self._client._call("browser.is_webview_focused", params)

    def browser_keydown(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (keydown)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("browser.keydown requires 'key'")
        return self._client._call("browser.keydown", params)

    def browser_keyup(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (keyup)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("browser.keyup requires 'key'")
        return self._client._call("browser.keyup", params)

    def browser_navigate(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (navigate)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("browser.navigate requires 'surface_id'")
        if params.get("url") is None:
            raise ProgramaV2Error("browser.navigate requires 'url'")
        return self._client._call("browser.navigate", params)

    def browser_network_requests(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (requests)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        return self._client._call("browser.network.requests", params)

    def browser_network_route(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (route)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        return self._client._call("browser.network.route", params)

    def browser_network_unroute(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (unroute)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        return self._client._call("browser.network.unroute", params)

    def browser_offline_set(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (set)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.offline.set", params)

    def browser_open_split(self, respect_external_open_rules: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (open split)."""
        params: Dict[str, Any] = {}
        if respect_external_open_rules is not None:
            params["respect_external_open_rules"] = respect_external_open_rules
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.open_split", params)

    def browser_press(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (press)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("browser.press requires 'key'")
        return self._client._call("browser.press", params)

    def browser_reload(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (reload)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.reload", params)

    def browser_screencast_start(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (start)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.screencast.start", params)

    def browser_screencast_stop(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (stop)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.screencast.stop", params)

    def browser_screenshot(self, _test_screenshot_pending_marker_path: Optional[Any] = None, _test_screenshot_release_marker_path: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (screenshot)."""
        params: Dict[str, Any] = {}
        if _test_screenshot_pending_marker_path is not None:
            params["_test_screenshot_pending_marker_path"] = _test_screenshot_pending_marker_path
        if _test_screenshot_release_marker_path is not None:
            params["_test_screenshot_release_marker_path"] = _test_screenshot_release_marker_path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.screenshot", params)

    def browser_scroll(self, dx: Optional[Any] = None, dy: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (scroll)."""
        params: Dict[str, Any] = {}
        if dx is not None:
            params["dx"] = dx
        if dy is not None:
            params["dy"] = dy
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.scroll", params)

    def browser_scroll_into_view(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (scroll into view)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.scroll_into_view", params)

    def browser_select(self, text: Optional[Any] = None, value: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (select)."""
        params: Dict[str, Any] = {}
        if text is not None:
            params["text"] = text
        if value is not None:
            params["value"] = value
        params.update(extra_params)
        return self._client._call("browser.select", params)

    def browser_snapshot(self, compact: Optional[Any] = None, cursor: Optional[Any] = None, interactive: Optional[Any] = None, maxDepth: Optional[Any] = None, max_depth: Optional[Any] = None, selector: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (snapshot)."""
        params: Dict[str, Any] = {}
        if compact is not None:
            params["compact"] = compact
        if cursor is not None:
            params["cursor"] = cursor
        if interactive is not None:
            params["interactive"] = interactive
        if maxDepth is not None:
            params["maxDepth"] = maxDepth
        if max_depth is not None:
            params["max_depth"] = max_depth
        if selector is not None:
            params["selector"] = selector
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.snapshot", params)

    def browser_state_load(self, path: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (load)."""
        params: Dict[str, Any] = {}
        if path is not None:
            params["path"] = path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("path") is None:
            raise ProgramaV2Error("browser.state.load requires 'path'")
        return self._client._call("browser.state.load", params)

    def browser_state_save(self, path: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (save)."""
        params: Dict[str, Any] = {}
        if path is not None:
            params["path"] = path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("path") is None:
            raise ProgramaV2Error("browser.state.save requires 'path'")
        return self._client._call("browser.state.save", params)

    def browser_storage_clear(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (clear)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.storage.clear", params)

    def browser_storage_get(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (get)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.storage.get", params)

    def browser_storage_set(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, value: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (set)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if value is not None:
            params["value"] = value
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("browser.storage.set requires 'key'")
        return self._client._call("browser.storage.set", params)

    def browser_tab_close(self, index: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, target_surface_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (close)."""
        params: Dict[str, Any] = {}
        if index is not None:
            params["index"] = index
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if target_surface_id is not None:
            params["target_surface_id"] = target_surface_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.tab.close", params)

    def browser_tab_list(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (list)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.tab.list", params)

    def browser_tab_new(self, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, target_pane_id: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (new)."""
        params: Dict[str, Any] = {}
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if target_pane_id is not None:
            params["target_pane_id"] = target_pane_id
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.tab.new", params)

    def browser_tab_switch(self, index: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, target_surface_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (switch)."""
        params: Dict[str, Any] = {}
        if index is not None:
            params["index"] = index
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if target_surface_id is not None:
            params["target_surface_id"] = target_surface_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.tab.switch", params)

    def browser_trace_start(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (start)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.trace.start", params)

    def browser_trace_stop(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (stop)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.trace.stop", params)

    def browser_type(self, text: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (type)."""
        params: Dict[str, Any] = {}
        if text is not None:
            params["text"] = text
        params.update(extra_params)
        if params.get("text") is None:
            raise ProgramaV2Error("browser.type requires 'text'")
        return self._client._call("browser.type", params)

    def browser_uncheck(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (uncheck)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.uncheck", params)

    def browser_url_get(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (get)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("browser.url.get requires 'surface_id'")
        return self._client._call("browser.url.get", params)

    def browser_viewport_set(self, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (set)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("browser.viewport.set", params)

    def browser_wait(self, function: Optional[Any] = None, load_state: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, text_contains: Optional[Any] = None, timeout_ms: Optional[Any] = None, url_contains: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Embedded browser automation (Playwright-like RPC surface). (wait)."""
        params: Dict[str, Any] = {}
        if function is not None:
            params["function"] = function
        if load_state is not None:
            params["load_state"] = load_state
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if text_contains is not None:
            params["text_contains"] = text_contains
        if timeout_ms is not None:
            params["timeout_ms"] = timeout_ms
        if url_contains is not None:
            params["url_contains"] = url_contains
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("browser.wait", params)

    def debug_app_activate(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (activate). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.app.activate", params)

    def debug_bonsplit_underflow_count(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (count). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.bonsplit_underflow.count", params)

    def debug_bonsplit_underflow_reset(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (reset). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.bonsplit_underflow.reset", params)

    def debug_browser_address_bar_focused(self, panel_id: Optional[Any] = None, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (address bar focused). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if panel_id is not None:
            params["panel_id"] = panel_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        return self._client._call("debug.browser.address_bar_focused", params)

    def debug_browser_favicon(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (favicon). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("debug.browser.favicon", params)

    def debug_command_palette_rename_input_delete_backward(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (delete backward). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        return self._client._call("debug.command_palette.rename_input.delete_backward", params)

    def debug_command_palette_rename_input_interact(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (interact). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        return self._client._call("debug.command_palette.rename_input.interact", params)

    def debug_command_palette_rename_input_selection(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (selection). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("debug.command_palette.rename_input.selection requires 'window_id'")
        return self._client._call("debug.command_palette.rename_input.selection", params)

    def debug_command_palette_rename_tab_open(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (open). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        return self._client._call("debug.command_palette.rename_tab.open", params)

    def debug_command_palette_results(self, limit: Optional[Any] = None, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (results). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if limit is not None:
            params["limit"] = limit
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("debug.command_palette.results requires 'window_id'")
        return self._client._call("debug.command_palette.results", params)

    def debug_command_palette_selection(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (selection). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("debug.command_palette.selection requires 'window_id'")
        return self._client._call("debug.command_palette.selection", params)

    def debug_command_palette_toggle(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (toggle). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        return self._client._call("debug.command_palette.toggle", params)

    def debug_command_palette_visible(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (visible). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("debug.command_palette.visible requires 'window_id'")
        return self._client._call("debug.command_palette.visible", params)

    def debug_empty_panel_count(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (count). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.empty_panel.count", params)

    def debug_empty_panel_reset(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (reset). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.empty_panel.reset", params)

    def debug_flash_count(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (count). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("debug.flash.count requires 'surface_id'")
        return self._client._call("debug.flash.count", params)

    def debug_flash_reset(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (reset). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.flash.reset", params)

    def debug_glass_set(self, enabled: Optional[Any] = None, surface: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (set). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if enabled is not None:
            params["enabled"] = enabled
        if surface is not None:
            params["surface"] = surface
        params.update(extra_params)
        if params.get("enabled") is None:
            raise ProgramaV2Error("debug.glass.set requires 'enabled'")
        if params.get("surface") is None:
            raise ProgramaV2Error("debug.glass.set requires 'surface'")
        return self._client._call("debug.glass.set", params)

    def debug_layout(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (layout). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.layout", params)

    def debug_notification_focus(self, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (focus). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("debug.notification.focus requires 'workspace_id'")
        return self._client._call("debug.notification.focus", params)

    def debug_panel_snapshot(self, label: Optional[Any] = None, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (panel snapshot). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if label is not None:
            params["label"] = label
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("debug.panel_snapshot requires 'surface_id'")
        return self._client._call("debug.panel_snapshot", params)

    def debug_panel_snapshot_reset(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (reset). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("debug.panel_snapshot.reset requires 'surface_id'")
        return self._client._call("debug.panel_snapshot.reset", params)

    def debug_portal_stats(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (stats). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.portal.stats", params)

    def debug_samples_reset(self, bucket: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (reset). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if bucket is not None:
            params["bucket"] = bucket
        params.update(extra_params)
        return self._client._call("debug.samples.reset", params)

    def debug_samples_stats(self, bucket: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (stats). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if bucket is not None:
            params["bucket"] = bucket
        params.update(extra_params)
        return self._client._call("debug.samples.stats", params)

    def debug_shortcut_set(self, combo: Optional[Any] = None, name: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (set). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if combo is not None:
            params["combo"] = combo
        if name is not None:
            params["name"] = name
        params.update(extra_params)
        if params.get("combo") is None:
            raise ProgramaV2Error("debug.shortcut.set requires 'combo'")
        if params.get("name") is None:
            raise ProgramaV2Error("debug.shortcut.set requires 'name'")
        return self._client._call("debug.shortcut.set", params)

    def debug_shortcut_simulate(self, combo: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (simulate). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if combo is not None:
            params["combo"] = combo
        params.update(extra_params)
        if params.get("combo") is None:
            raise ProgramaV2Error("debug.shortcut.simulate requires 'combo'")
        return self._client._call("debug.shortcut.simulate", params)

    def debug_sidebar_visible(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (visible). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("debug.sidebar.visible requires 'window_id'")
        return self._client._call("debug.sidebar.visible", params)

    def debug_terminal_is_focused(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (is focused). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("debug.terminal.is_focused requires 'surface_id'")
        return self._client._call("debug.terminal.is_focused", params)

    def debug_terminal_read_text(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (read text). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        return self._client._call("debug.terminal.read_text", params)

    def debug_terminal_render_stats(self, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (render stats). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        return self._client._call("debug.terminal.render_stats", params)

    def debug_terminals(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (terminals)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.terminals", params)

    def debug_type(self, text: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (type). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if text is not None:
            params["text"] = text
        params.update(extra_params)
        if params.get("text") is None:
            raise ProgramaV2Error("debug.type requires 'text'")
        return self._client._call("debug.type", params)

    def debug_viewtree(self, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (viewtree). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("debug.viewtree", params)

    def debug_window_screenshot(self, label: Optional[Any] = None, **extra_params: Any) -> Any:
        """DEBUG-build-only introspection and simulation. (screenshot). (DEBUG builds only)"""
        params: Dict[str, Any] = {}
        if label is not None:
            params["label"] = label
        params.update(extra_params)
        return self._client._call("debug.window.screenshot", params)

    def feedback_open(self, activate: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """In-app feedback capture. (open)."""
        params: Dict[str, Any] = {}
        if activate is not None:
            params["activate"] = activate
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("feedback.open", params)

    def feedback_submit(self, **extra_params: Any) -> Any:
        """In-app feedback capture. (submit)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("feedback.submit", params)

    def layout_apply(self, cwd: Optional[Any] = None, name: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Saved workspace layouts. (apply)."""
        params: Dict[str, Any] = {}
        if cwd is not None:
            params["cwd"] = cwd
        if name is not None:
            params["name"] = name
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("layout.apply", params)

    def layout_list(self, **extra_params: Any) -> Any:
        """Saved workspace layouts. (list)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("layout.list", params)

    def layout_save(self, force: Optional[Any] = None, name: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Saved workspace layouts. (save)."""
        params: Dict[str, Any] = {}
        if force is not None:
            params["force"] = force
        if name is not None:
            params["name"] = name
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("layout.save", params)

    def markdown_open(self, direction: Optional[Any] = None, path: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Markdown preview panel. (open)."""
        params: Dict[str, Any] = {}
        if direction is not None:
            params["direction"] = direction
        if path is not None:
            params["path"] = path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("path") is None:
            raise ProgramaV2Error("markdown.open requires 'path'")
        return self._client._call("markdown.open", params)

    def notification_clear(self, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """In-app notification center. (clear)."""
        params: Dict[str, Any] = {}
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("notification.clear", params)

    def notification_create(self, body: Optional[Any] = None, subtitle: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """In-app notification center. (create)."""
        params: Dict[str, Any] = {}
        if body is not None:
            params["body"] = body
        if subtitle is not None:
            params["subtitle"] = subtitle
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("notification.create", params)

    def notification_create_for_surface(self, body: Optional[Any] = None, subtitle: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """In-app notification center. (create for surface)."""
        params: Dict[str, Any] = {}
        if body is not None:
            params["body"] = body
        if subtitle is not None:
            params["subtitle"] = subtitle
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("notification.create_for_surface", params)

    def notification_create_for_target(self, body: Optional[Any] = None, subtitle: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """In-app notification center. (create for target)."""
        params: Dict[str, Any] = {}
        if body is not None:
            params["body"] = body
        if subtitle is not None:
            params["subtitle"] = subtitle
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("notification.create_for_target", params)

    def notification_list(self, **extra_params: Any) -> Any:
        """In-app notification center. (list)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("notification.list", params)

    def pane_break(self, focus: Optional[Any] = None, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (break)."""
        params: Dict[str, Any] = {}
        if focus is not None:
            params["focus"] = focus
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("pane.break", params)

    def pane_create(self, direction: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (create)."""
        params: Dict[str, Any] = {}
        if direction is not None:
            params["direction"] = direction
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("direction") is None:
            raise ProgramaV2Error("pane.create requires 'direction'")
        return self._client._call("pane.create", params)

    def pane_focus(self, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (focus)."""
        params: Dict[str, Any] = {}
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("pane_id") is None:
            raise ProgramaV2Error("pane.focus requires 'pane_id'")
        return self._client._call("pane.focus", params)

    def pane_join(self, focus: Optional[Any] = None, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, target_pane_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (join)."""
        params: Dict[str, Any] = {}
        if focus is not None:
            params["focus"] = focus
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if target_pane_id is not None:
            params["target_pane_id"] = target_pane_id
        params.update(extra_params)
        if params.get("target_pane_id") is None:
            raise ProgramaV2Error("pane.join requires 'target_pane_id'")
        return self._client._call("pane.join", params)

    def pane_last(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (last)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("pane.last", params)

    def pane_list(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (list)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("pane.list", params)

    def pane_resize(self, amount: Optional[Any] = None, direction: Optional[Any] = None, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (resize)."""
        params: Dict[str, Any] = {}
        if amount is not None:
            params["amount"] = amount
        if direction is not None:
            params["direction"] = direction
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("amount") is None:
            raise ProgramaV2Error("pane.resize requires 'amount'")
        return self._client._call("pane.resize", params)

    def pane_surfaces(self, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (surfaces)."""
        params: Dict[str, Any] = {}
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("pane.surfaces", params)

    def pane_swap(self, focus: Optional[Any] = None, pane_id: Optional[Any] = None, target_pane_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Split-pane layout management. (swap)."""
        params: Dict[str, Any] = {}
        if focus is not None:
            params["focus"] = focus
        if pane_id is not None:
            params["pane_id"] = pane_id
        if target_pane_id is not None:
            params["target_pane_id"] = target_pane_id
        params.update(extra_params)
        if params.get("pane_id") is None:
            raise ProgramaV2Error("pane.swap requires 'pane_id'")
        if params.get("target_pane_id") is None:
            raise ProgramaV2Error("pane.swap requires 'target_pane_id'")
        return self._client._call("pane.swap", params)

    def review_comment_add(self, end_line: Optional[Any] = None, file_path: Optional[Any] = None, start_line: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, text: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Code review panel and comments. (add)."""
        params: Dict[str, Any] = {}
        if end_line is not None:
            params["end_line"] = end_line
        if file_path is not None:
            params["file_path"] = file_path
        if start_line is not None:
            params["start_line"] = start_line
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if text is not None:
            params["text"] = text
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("review.comment.add", params)

    def review_comment_list(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Code review panel and comments. (list)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("review.comment.list", params)

    def review_comment_remove(self, comment_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Code review panel and comments. (remove)."""
        params: Dict[str, Any] = {}
        if comment_id is not None:
            params["comment_id"] = comment_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("review.comment.remove", params)

    def review_open(self, base_branch: Optional[Any] = None, direction: Optional[Any] = None, focus: Optional[Any] = None, mode: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Code review panel and comments. (open)."""
        params: Dict[str, Any] = {}
        if base_branch is not None:
            params["base_branch"] = base_branch
        if direction is not None:
            params["direction"] = direction
        if focus is not None:
            params["focus"] = focus
        if mode is not None:
            params["mode"] = mode
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("review.open", params)

    def review_refresh(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Code review panel and comments. (refresh)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("review.refresh", params)

    def review_send_comments(self, preamble: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Code review panel and comments. (send comments)."""
        params: Dict[str, Any] = {}
        if preamble is not None:
            params["preamble"] = preamble
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("review.send_comments", params)

    def settings_open(self, activate: Optional[Any] = None, target: Optional[Any] = None, **extra_params: Any) -> Any:
        """App settings surface. (open)."""
        params: Dict[str, Any] = {}
        if activate is not None:
            params["activate"] = activate
        if target is not None:
            params["target"] = target
        params.update(extra_params)
        return self._client._call("settings.open", params)

    def snapshot_list(self, **extra_params: Any) -> Any:
        """Workspace/pane snapshots. (list)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("snapshot.list", params)

    def snapshot_restore(self, id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace/pane snapshots. (restore)."""
        params: Dict[str, Any] = {}
        if id is not None:
            params["id"] = id
        params.update(extra_params)
        return self._client._call("snapshot.restore", params)

    def subscribe(self, classes: Optional[Any] = None, surface_ids: Optional[Any] = None, **extra_params: Any) -> Any:
        """Event subscription. (subscribe)."""
        params: Dict[str, Any] = {}
        if classes is not None:
            params["classes"] = classes
        if surface_ids is not None:
            params["surface_ids"] = surface_ids
        params.update(extra_params)
        if params.get("classes") is None:
            raise ProgramaV2Error("subscribe requires 'classes'")
        if params.get("surface_ids") is None:
            raise ProgramaV2Error("subscribe requires 'surface_ids'")
        return self._client._call("subscribe", params)

    def surface_action(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (action)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("title") is None:
            raise ProgramaV2Error("surface.action requires 'title'")
        return self._client._call("surface.action", params)

    def surface_clear_agent_state(self, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (clear agent state)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.clear_agent_state requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.clear_agent_state requires 'workspace_id'")
        return self._client._call("surface.clear_agent_state", params)

    def surface_clear_git_branch(self, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (clear git branch)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.clear_git_branch requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.clear_git_branch requires 'workspace_id'")
        return self._client._call("surface.clear_git_branch", params)

    def surface_clear_history(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (clear history)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.clear_history", params)

    def surface_clear_ports(self, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (clear ports)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.clear_ports requires 'workspace_id'")
        return self._client._call("surface.clear_ports", params)

    def surface_clear_pr(self, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (clear pr)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.clear_pr requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.clear_pr requires 'workspace_id'")
        return self._client._call("surface.clear_pr", params)

    def surface_close(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (close)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.close", params)

    def surface_create(self, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (create)."""
        params: Dict[str, Any] = {}
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.create", params)

    def surface_current(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (current)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.current", params)

    def surface_drag_to_split(self, direction: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (drag to split)."""
        params: Dict[str, Any] = {}
        if direction is not None:
            params["direction"] = direction
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("direction") is None:
            raise ProgramaV2Error("surface.drag_to_split requires 'direction'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.drag_to_split requires 'surface_id'")
        return self._client._call("surface.drag_to_split", params)

    def surface_focus(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (focus)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.focus requires 'surface_id'")
        return self._client._call("surface.focus", params)

    def surface_health(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (health)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.health", params)

    def surface_list(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (list)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.list", params)

    def surface_move(self, after_surface_id: Optional[Any] = None, before_surface_id: Optional[Any] = None, focus: Optional[Any] = None, index: Optional[Any] = None, pane_id: Optional[Any] = None, surface_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (move)."""
        params: Dict[str, Any] = {}
        if after_surface_id is not None:
            params["after_surface_id"] = after_surface_id
        if before_surface_id is not None:
            params["before_surface_id"] = before_surface_id
        if focus is not None:
            params["focus"] = focus
        if index is not None:
            params["index"] = index
        if pane_id is not None:
            params["pane_id"] = pane_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.move requires 'surface_id'")
        return self._client._call("surface.move", params)

    def surface_ports_kick(self, reason: Optional[Any] = None, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (ports kick)."""
        params: Dict[str, Any] = {}
        if reason is not None:
            params["reason"] = reason
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("reason") is None:
            raise ProgramaV2Error("surface.ports_kick requires 'reason'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.ports_kick requires 'workspace_id'")
        return self._client._call("surface.ports_kick", params)

    def surface_read_text(self, lines: Optional[Any] = None, scrollback: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (read text)."""
        params: Dict[str, Any] = {}
        if lines is not None:
            params["lines"] = lines
        if scrollback is not None:
            params["scrollback"] = scrollback
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.read_text", params)

    def surface_refresh(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (refresh)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.refresh", params)

    def surface_reorder(self, after_surface_id: Optional[Any] = None, before_surface_id: Optional[Any] = None, index: Optional[Any] = None, surface_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (reorder)."""
        params: Dict[str, Any] = {}
        if after_surface_id is not None:
            params["after_surface_id"] = after_surface_id
        if before_surface_id is not None:
            params["before_surface_id"] = before_surface_id
        if index is not None:
            params["index"] = index
        if surface_id is not None:
            params["surface_id"] = surface_id
        params.update(extra_params)
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.reorder requires 'surface_id'")
        return self._client._call("surface.reorder", params)

    def surface_report_agent_state(self, pid: Optional[Any] = None, provider: Optional[Any] = None, session_id: Optional[Any] = None, source: Optional[Any] = None, state: Optional[Any] = None, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report agent state)."""
        params: Dict[str, Any] = {}
        if pid is not None:
            params["pid"] = pid
        if provider is not None:
            params["provider"] = provider
        if session_id is not None:
            params["session_id"] = session_id
        if source is not None:
            params["source"] = source
        if state is not None:
            params["state"] = state
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("state") is None:
            raise ProgramaV2Error("surface.report_agent_state requires 'state'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.report_agent_state requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_agent_state requires 'workspace_id'")
        return self._client._call("surface.report_agent_state", params)

    def surface_report_git_branch(self, branch: Optional[Any] = None, dirty: Optional[Any] = None, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report git branch)."""
        params: Dict[str, Any] = {}
        if branch is not None:
            params["branch"] = branch
        if dirty is not None:
            params["dirty"] = dirty
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("branch") is None:
            raise ProgramaV2Error("surface.report_git_branch requires 'branch'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.report_git_branch requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_git_branch requires 'workspace_id'")
        return self._client._call("surface.report_git_branch", params)

    def surface_report_ports(self, ports: Optional[Any] = None, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report ports)."""
        params: Dict[str, Any] = {}
        if ports is not None:
            params["ports"] = ports
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("ports") is None:
            raise ProgramaV2Error("surface.report_ports requires 'ports'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.report_ports requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_ports requires 'workspace_id'")
        return self._client._call("surface.report_ports", params)

    def surface_report_pr(self, branch: Optional[Any] = None, checks: Optional[Any] = None, label: Optional[Any] = None, number: Optional[Any] = None, state: Optional[Any] = None, surface_id: Optional[Any] = None, url: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report pr)."""
        params: Dict[str, Any] = {}
        if branch is not None:
            params["branch"] = branch
        if checks is not None:
            params["checks"] = checks
        if label is not None:
            params["label"] = label
        if number is not None:
            params["number"] = number
        if state is not None:
            params["state"] = state
        if surface_id is not None:
            params["surface_id"] = surface_id
        if url is not None:
            params["url"] = url
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("number") is None:
            raise ProgramaV2Error("surface.report_pr requires 'number'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.report_pr requires 'surface_id'")
        if params.get("url") is None:
            raise ProgramaV2Error("surface.report_pr requires 'url'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_pr requires 'workspace_id'")
        return self._client._call("surface.report_pr", params)

    def surface_report_pwd(self, path: Optional[Any] = None, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report pwd)."""
        params: Dict[str, Any] = {}
        if path is not None:
            params["path"] = path
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("path") is None:
            raise ProgramaV2Error("surface.report_pwd requires 'path'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.report_pwd requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_pwd requires 'workspace_id'")
        return self._client._call("surface.report_pwd", params)

    def surface_report_shell_state(self, state: Optional[Any] = None, surface_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report shell state)."""
        params: Dict[str, Any] = {}
        if state is not None:
            params["state"] = state
        if surface_id is not None:
            params["surface_id"] = surface_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("state") is None:
            raise ProgramaV2Error("surface.report_shell_state requires 'state'")
        if params.get("surface_id") is None:
            raise ProgramaV2Error("surface.report_shell_state requires 'surface_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_shell_state requires 'workspace_id'")
        return self._client._call("surface.report_shell_state", params)

    def surface_report_tty(self, surface_id: Optional[Any] = None, tty_name: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (report tty)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tty_name is not None:
            params["tty_name"] = tty_name
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("tty_name") is None:
            raise ProgramaV2Error("surface.report_tty requires 'tty_name'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("surface.report_tty requires 'workspace_id'")
        return self._client._call("surface.report_tty", params)

    def surface_send_key(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (send key)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("surface.send_key requires 'key'")
        return self._client._call("surface.send_key", params)

    def surface_send_text(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, text: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (send text)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if text is not None:
            params["text"] = text
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("text") is None:
            raise ProgramaV2Error("surface.send_text requires 'text'")
        return self._client._call("surface.send_text", params)

    def surface_split(self, direction: Optional[Any] = None, focus: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (split)."""
        params: Dict[str, Any] = {}
        if direction is not None:
            params["direction"] = direction
        if focus is not None:
            params["focus"] = focus
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("direction") is None:
            raise ProgramaV2Error("surface.split requires 'direction'")
        return self._client._call("surface.split", params)

    def surface_trigger_flash(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (trigger flash)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.trigger_flash", params)

    def surface_wait(self, agent_state: Optional[Any] = None, exit: Optional[Any] = None, lines: Optional[Any] = None, pattern: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, timeout: Optional[Any] = None, timeout_ms: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Terminal surface (pane content) lifecycle and IO. (wait)."""
        params: Dict[str, Any] = {}
        if agent_state is not None:
            params["agent_state"] = agent_state
        if exit is not None:
            params["exit"] = exit
        if lines is not None:
            params["lines"] = lines
        if pattern is not None:
            params["pattern"] = pattern
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if timeout is not None:
            params["timeout"] = timeout
        if timeout_ms is not None:
            params["timeout_ms"] = timeout_ms
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("surface.wait", params)

    def system_capabilities(self, **extra_params: Any) -> Any:
        """Server/process introspection and identification. (capabilities)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("system.capabilities", params)

    def system_identify(self, caller: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Server/process introspection and identification. (identify)."""
        params: Dict[str, Any] = {}
        if caller is not None:
            params["caller"] = caller
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("system.identify", params)

    def system_ping(self, **extra_params: Any) -> Any:
        """Server/process introspection and identification. (ping)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("system.ping", params)

    def system_tree(self, all_windows: Optional[Any] = None, caller: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Server/process introspection and identification. (tree)."""
        params: Dict[str, Any] = {}
        if all_windows is not None:
            params["all_windows"] = all_windows
        if caller is not None:
            params["caller"] = caller
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("system.tree", params)

    def tab_action(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, url: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Tab-level actions. (action)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if url is not None:
            params["url"] = url
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("title") is None:
            raise ProgramaV2Error("tab.action requires 'title'")
        return self._client._call("tab.action", params)

    def unsubscribe(self, **extra_params: Any) -> Any:
        """Event unsubscription. (unsubscribe)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("unsubscribe", params)

    def window_close(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Top-level OS window management. (close)."""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("window.close requires 'window_id'")
        return self._client._call("window.close", params)

    def window_create(self, **extra_params: Any) -> Any:
        """Top-level OS window management. (create)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("window.create", params)

    def window_current(self, **extra_params: Any) -> Any:
        """Top-level OS window management. (current)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("window.current", params)

    def window_focus(self, window_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Top-level OS window management. (focus)."""
        params: Dict[str, Any] = {}
        if window_id is not None:
            params["window_id"] = window_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("window.focus requires 'window_id'")
        return self._client._call("window.focus", params)

    def window_list(self, **extra_params: Any) -> Any:
        """Top-level OS window management. (list)."""
        params: Dict[str, Any] = {}
        params.update(extra_params)
        return self._client._call("window.list", params)

    def workspace_action(self, color: Optional[Any] = None, description: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (action)."""
        params: Dict[str, Any] = {}
        if color is not None:
            params["color"] = color
        if description is not None:
            params["description"] = description
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("color") is None:
            raise ProgramaV2Error("workspace.action requires 'color'")
        if params.get("description") is None:
            raise ProgramaV2Error("workspace.action requires 'description'")
        if params.get("title") is None:
            raise ProgramaV2Error("workspace.action requires 'title'")
        return self._client._call("workspace.action", params)

    def workspace_clear_agent_pid(self, key: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (clear agent pid)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("workspace.clear_agent_pid requires 'key'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.clear_agent_pid requires 'workspace_id'")
        return self._client._call("workspace.clear_agent_pid", params)

    def workspace_clear_log(self, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (clear log)."""
        params: Dict[str, Any] = {}
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.clear_log requires 'workspace_id'")
        return self._client._call("workspace.clear_log", params)

    def workspace_clear_meta_block(self, key: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (clear meta block)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("workspace.clear_meta_block requires 'key'")
        return self._client._call("workspace.clear_meta_block", params)

    def workspace_clear_progress(self, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (clear progress)."""
        params: Dict[str, Any] = {}
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.clear_progress requires 'workspace_id'")
        return self._client._call("workspace.clear_progress", params)

    def workspace_clear_status(self, key: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (clear status)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("workspace.clear_status requires 'key'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.clear_status requires 'workspace_id'")
        return self._client._call("workspace.clear_status", params)

    def workspace_close(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (close)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.close requires 'workspace_id'")
        return self._client._call("workspace.close", params)

    def workspace_create(self, apply_remembered_folder_color: Optional[Any] = None, cwd: Optional[Any] = None, description: Optional[Any] = None, initial_command: Optional[Any] = None, initial_env: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, window_id: Optional[Any] = None, working_directory: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (create)."""
        params: Dict[str, Any] = {}
        if apply_remembered_folder_color is not None:
            params["apply_remembered_folder_color"] = apply_remembered_folder_color
        if cwd is not None:
            params["cwd"] = cwd
        if description is not None:
            params["description"] = description
        if initial_command is not None:
            params["initial_command"] = initial_command
        if initial_env is not None:
            params["initial_env"] = initial_env
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if window_id is not None:
            params["window_id"] = window_id
        if working_directory is not None:
            params["working_directory"] = working_directory
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.create", params)

    def workspace_current(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (current)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.current", params)

    def workspace_equalize_splits(self, orientation: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (equalize splits)."""
        params: Dict[str, Any] = {}
        if orientation is not None:
            params["orientation"] = orientation
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.equalize_splits", params)

    def workspace_last(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (last)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.last", params)

    def workspace_list(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (list)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.list", params)

    def workspace_list_log(self, limit: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (list log)."""
        params: Dict[str, Any] = {}
        if limit is not None:
            params["limit"] = limit
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("limit") is None:
            raise ProgramaV2Error("workspace.list_log requires 'limit'")
        return self._client._call("workspace.list_log", params)

    def workspace_list_meta_blocks(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (list meta blocks)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.list_meta_blocks", params)

    def workspace_list_status(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (list status)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.list_status", params)

    def workspace_log(self, level: Optional[Any] = None, message: Optional[Any] = None, source: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (log)."""
        params: Dict[str, Any] = {}
        if level is not None:
            params["level"] = level
        if message is not None:
            params["message"] = message
        if source is not None:
            params["source"] = source
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("message") is None:
            raise ProgramaV2Error("workspace.log requires 'message'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.log requires 'workspace_id'")
        return self._client._call("workspace.log", params)

    def workspace_move_to_window(self, focus: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (move to window)."""
        params: Dict[str, Any] = {}
        if focus is not None:
            params["focus"] = focus
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("window_id") is None:
            raise ProgramaV2Error("workspace.move_to_window requires 'window_id'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.move_to_window requires 'workspace_id'")
        return self._client._call("workspace.move_to_window", params)

    def workspace_next(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (next)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.next", params)

    def workspace_previous(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (previous)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.previous", params)

    def workspace_rename(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, title: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (rename)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if title is not None:
            params["title"] = title
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("title") is None:
            raise ProgramaV2Error("workspace.rename requires 'title'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.rename requires 'workspace_id'")
        return self._client._call("workspace.rename", params)

    def workspace_reorder(self, after_workspace_id: Optional[Any] = None, before_workspace_id: Optional[Any] = None, index: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (reorder)."""
        params: Dict[str, Any] = {}
        if after_workspace_id is not None:
            params["after_workspace_id"] = after_workspace_id
        if before_workspace_id is not None:
            params["before_workspace_id"] = before_workspace_id
        if index is not None:
            params["index"] = index
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.reorder requires 'workspace_id'")
        return self._client._call("workspace.reorder", params)

    def workspace_report_meta_block(self, key: Optional[Any] = None, markdown: Optional[Any] = None, priority: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (report meta block)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if markdown is not None:
            params["markdown"] = markdown
        if priority is not None:
            params["priority"] = priority
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("workspace.report_meta_block requires 'key'")
        if params.get("markdown") is None:
            raise ProgramaV2Error("workspace.report_meta_block requires 'markdown'")
        if params.get("priority") is None:
            raise ProgramaV2Error("workspace.report_meta_block requires 'priority'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.report_meta_block requires 'workspace_id'")
        return self._client._call("workspace.report_meta_block", params)

    def workspace_reset_sidebar(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (reset sidebar)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.reset_sidebar", params)

    def workspace_select(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (select)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.select requires 'workspace_id'")
        return self._client._call("workspace.select", params)

    def workspace_set_agent_pid(self, key: Optional[Any] = None, pid: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (set agent pid)."""
        params: Dict[str, Any] = {}
        if key is not None:
            params["key"] = key
        if pid is not None:
            params["pid"] = pid
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("workspace.set_agent_pid requires 'key'")
        if params.get("pid") is None:
            raise ProgramaV2Error("workspace.set_agent_pid requires 'pid'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.set_agent_pid requires 'workspace_id'")
        return self._client._call("workspace.set_agent_pid", params)

    def workspace_set_progress(self, label: Optional[Any] = None, value: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (set progress)."""
        params: Dict[str, Any] = {}
        if label is not None:
            params["label"] = label
        if value is not None:
            params["value"] = value
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("value") is None:
            raise ProgramaV2Error("workspace.set_progress requires 'value'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.set_progress requires 'workspace_id'")
        return self._client._call("workspace.set_progress", params)

    def workspace_set_status(self, color: Optional[Any] = None, format: Optional[Any] = None, icon: Optional[Any] = None, key: Optional[Any] = None, pid: Optional[Any] = None, priority: Optional[Any] = None, url: Optional[Any] = None, value: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (set status)."""
        params: Dict[str, Any] = {}
        if color is not None:
            params["color"] = color
        if format is not None:
            params["format"] = format
        if icon is not None:
            params["icon"] = icon
        if key is not None:
            params["key"] = key
        if pid is not None:
            params["pid"] = pid
        if priority is not None:
            params["priority"] = priority
        if url is not None:
            params["url"] = url
        if value is not None:
            params["value"] = value
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("key") is None:
            raise ProgramaV2Error("workspace.set_status requires 'key'")
        if params.get("pid") is None:
            raise ProgramaV2Error("workspace.set_status requires 'pid'")
        if params.get("priority") is None:
            raise ProgramaV2Error("workspace.set_status requires 'priority'")
        if params.get("value") is None:
            raise ProgramaV2Error("workspace.set_status requires 'value'")
        if params.get("workspace_id") is None:
            raise ProgramaV2Error("workspace.set_status requires 'workspace_id'")
        return self._client._call("workspace.set_status", params)

    def workspace_sidebar_state(self, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Workspace (tab) lifecycle, ordering, and metadata. (sidebar state)."""
        params: Dict[str, Any] = {}
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("workspace.sidebar_state", params)

    def worktree_create(self, base: Optional[Any] = None, branch: Optional[Any] = None, focus: Optional[Any] = None, layout: Optional[Any] = None, repo: Optional[Any] = None, required_parent_directory: Optional[Any] = None, required_parent_workspace_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Git worktree lifecycle. (create)."""
        params: Dict[str, Any] = {}
        if base is not None:
            params["base"] = base
        if branch is not None:
            params["branch"] = branch
        if focus is not None:
            params["focus"] = focus
        if layout is not None:
            params["layout"] = layout
        if repo is not None:
            params["repo"] = repo
        if required_parent_directory is not None:
            params["required_parent_directory"] = required_parent_directory
        if required_parent_workspace_id is not None:
            params["required_parent_workspace_id"] = required_parent_workspace_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        if params.get("branch") is None:
            raise ProgramaV2Error("worktree.create requires 'branch'")
        return self._client._call("worktree.create", params)

    def worktree_list(self, repo: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Git worktree lifecycle. (list)."""
        params: Dict[str, Any] = {}
        if repo is not None:
            params["repo"] = repo
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("worktree.list", params)

    def worktree_open(self, branch: Optional[Any] = None, focus: Optional[Any] = None, path: Optional[Any] = None, repo: Optional[Any] = None, required_parent_directory: Optional[Any] = None, required_parent_workspace_id: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Git worktree lifecycle. (open)."""
        params: Dict[str, Any] = {}
        if branch is not None:
            params["branch"] = branch
        if focus is not None:
            params["focus"] = focus
        if path is not None:
            params["path"] = path
        if repo is not None:
            params["repo"] = repo
        if required_parent_directory is not None:
            params["required_parent_directory"] = required_parent_directory
        if required_parent_workspace_id is not None:
            params["required_parent_workspace_id"] = required_parent_workspace_id
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("worktree.open", params)

    def worktree_remove(self, branch: Optional[Any] = None, force: Optional[Any] = None, path: Optional[Any] = None, repo: Optional[Any] = None, surface_id: Optional[Any] = None, tab_id: Optional[Any] = None, window_id: Optional[Any] = None, workspace_id: Optional[Any] = None, **extra_params: Any) -> Any:
        """Git worktree lifecycle. (remove)."""
        params: Dict[str, Any] = {}
        if branch is not None:
            params["branch"] = branch
        if force is not None:
            params["force"] = force
        if path is not None:
            params["path"] = path
        if repo is not None:
            params["repo"] = repo
        if surface_id is not None:
            params["surface_id"] = surface_id
        if tab_id is not None:
            params["tab_id"] = tab_id
        if window_id is not None:
            params["window_id"] = window_id
        if workspace_id is not None:
            params["workspace_id"] = workspace_id
        params.update(extra_params)
        return self._client._call("worktree.remove", params)

