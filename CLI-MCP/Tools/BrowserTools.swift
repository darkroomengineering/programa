import MCP

/// `browser.*` tools other than the three focus-stealing browser methods (`browser.focus_webview`,
/// `browser.focus`, `browser.tab.switch` -- see `FocusTools.swift`). Handlers live in
/// `Sources/TerminalController+BrowserAutomation.swift`; the socket dispatch table is
/// `Sources/BrowserRPCDispatcher.swift`.
///
/// The embedded browser is a per-workspace WKWebView, not a Chromium/CDP surface, so several
/// Playwright-shaped methods here (`viewport.set`, `geolocation.set`, `offline.set`,
/// `trace.start`/`stop`, `network.route`/`unroute`/`requests`, `screencast.start`/`stop`,
/// `input_mouse`/`input_keyboard`/`input_touch`) are always-`not_supported` stubs on this
/// platform; they are still exposed so a caller gets a clear "not supported on WKWebView" error
/// instead of an unknown-tool error, and so the tool list matches the full socket method surface.
///
/// Almost every tool here resolves its target with `surface_id` (falling back to the workspace's
/// focused browser surface when omitted) via `v2BrowserWithPanel`/`v2ResolveWorkspace`, the same
/// fallback chain documented on `ProgramaToolSchema.surfaceRoutingIdProperty` -- these tools use a
/// local, more specific `surface_id` description instead of that shared one because `surface_id`
/// is their primary target, not just a routing fallback.
///
/// `browser_open_split` and `browser_tab_new` create new browser UI but never move keyboard focus
/// or raise/activate the Programa window: both call into focus-adjacent app APIs internally, but
/// those APIs are gated by `socketCommandAllowsInAppFocusMutations` (`Sources/
/// TerminalController.swift`), which only allows the mutation for methods in `focusIntentV2Methods`
/// -- and `browser.open_split`/`browser.tab.new` are not in that set. Neither handler exposes a
/// caller-controlled `focus` parameter, so there is nothing to strip from these schemas the way
/// `worktree_create` strips `focus` in `WorktreeTools.swift`.
enum BrowserTools {
    private static let selectorProperty = ProgramaToolSchema.string(
        "CSS selector identifying the target element. Also accepts sel, element_ref, or ref as aliases (e.g. a ref returned by browser_find_role/browser_snapshot)."
    )

    private static let retryAttemptsProperty = ProgramaToolSchema.integer(
        "Number of times to retry if the selector doesn't resolve yet (useful for elements that render asynchronously). Defaults to 3."
    )

    private static let exactProperty = ProgramaToolSchema.boolean(
        "If true, require an exact match instead of a substring/contains match. Defaults to false."
    )

    private static func surfaceIdProperty(_ extra: String = "") -> Value {
        ProgramaToolSchema.string(
            "Browser surface UUID or short ref (e.g. surface:3) to target. Defaults to the workspace's focused browser surface if omitted." + extra
        )
    }

    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "browser_open_split",
            socketMethod: "browser.open_split",
            description: "Opens a new browser surface as a split next to a source surface (or reuses an existing sibling browser pane when one is already positioned to the right). Never raises/activates the Programa window or switches the selected workspace; inside the target workspace the new tab becomes that workspace's focused surface, so the user only sees a change if they are already looking at that workspace. Returns the new surface_id.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "url": ProgramaToolSchema.string("Initial URL to load. Opens a blank browser tab if omitted."),
                "respect_external_open_rules": ProgramaToolSchema.boolean("If true, URLs matched by the user's configured external-open rules are opened in the default system browser instead of inside Programa. Defaults to false."),
                "surface_id": ProgramaToolSchema.string("Source surface UUID or short ref to split from. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_navigate",
            socketMethod: "browser.navigate",
            description: "Navigates an existing browser surface to a URL.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": surfaceIdProperty(" Required (this tool does not fall back to the focused surface)."),
                    "url": ProgramaToolSchema.string("URL to navigate to."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id", "url"]
            )
        ),
        ProgramaTool(
            name: "browser_back",
            socketMethod: "browser.back",
            description: "Navigates a browser surface back one entry in its history.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": surfaceIdProperty(" Required (this tool does not fall back to the focused surface)."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "browser_forward",
            socketMethod: "browser.forward",
            description: "Navigates a browser surface forward one entry in its history.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": surfaceIdProperty(" Required (this tool does not fall back to the focused surface)."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "browser_reload",
            socketMethod: "browser.reload",
            description: "Reloads a browser surface's current page.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": surfaceIdProperty(" Required (this tool does not fall back to the focused surface)."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "browser_url_get",
            socketMethod: "browser.url.get",
            description: "Returns a browser surface's current URL.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": surfaceIdProperty(" Required (this tool does not fall back to the focused surface)."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "browser_is_webview_focused",
            socketMethod: "browser.is_webview_focused",
            description: "Reports whether keyboard focus is currently inside a browser surface's web view. Read-only; does not move focus.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": surfaceIdProperty(" Required (this tool does not fall back to the focused surface)."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "browser_snapshot",
            socketMethod: "browser.snapshot",
            description: "Returns an accessibility-tree-style snapshot of the page (roles, names, and element refs usable by selector-based tools), plus title/url/ready_state and the page text/HTML.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "interactive": ProgramaToolSchema.boolean("If true, include only interactive elements (links, buttons, inputs, etc). Defaults to false (include the full tree)."),
                "cursor": ProgramaToolSchema.boolean("If true, include cursor-style metadata in the snapshot. Defaults to false."),
                "compact": ProgramaToolSchema.boolean("If true, produce a more compact tree. Defaults to false."),
                "max_depth": ProgramaToolSchema.integer("Maximum tree depth to walk, from 0 to 64. Defaults to 12."),
                "selector": ProgramaToolSchema.string("Optional CSS selector to scope the snapshot to a subtree instead of the whole document."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_eval",
            socketMethod: "browser.eval",
            description: "Runs arbitrary JavaScript in the browser surface's page context and returns its result (JSON-normalized).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "script": ProgramaToolSchema.string("JavaScript expression or statement(s) to evaluate."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["script"]
            )
        ),
        ProgramaTool(
            name: "browser_wait",
            socketMethod: "browser.wait",
            description: "Waits (up to a timeout) for a condition to become true: a selector to appear, the URL to contain a substring, the page text to contain a substring, a document.readyState value, or a custom JS boolean expression. Provide at most one condition; defaults to waiting for document.readyState === 'complete'.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "timeout_ms": ProgramaToolSchema.integer("Maximum time to wait, in milliseconds. Defaults to 5000."),
                "selector": selectorProperty,
                "url_contains": ProgramaToolSchema.string("Wait until location.href contains this substring."),
                "text_contains": ProgramaToolSchema.string("Wait until document.body's text contains this substring."),
                "load_state": ProgramaToolSchema.stringEnum("Wait until document.readyState reaches this state ('interactive' also matches 'complete').", ["loading", "interactive", "complete"]),
                "function": ProgramaToolSchema.string("Custom JavaScript boolean expression to poll, e.g. 'window.myFlag === true'."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_click",
            socketMethod: "browser.click",
            description: "Clicks the element matched by a selector (scrolls it into view first, dispatches a real click event or calls .click()).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_dblclick",
            socketMethod: "browser.dblclick",
            description: "Double-clicks the element matched by a selector.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_hover",
            socketMethod: "browser.hover",
            description: "Hovers the element matched by a selector (dispatches mouseover/mouseenter events).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_type",
            socketMethod: "browser.type",
            description: "Appends text to the element matched by a selector (focuses it, then appends to its value/textContent and fires input/change events). Use browser_fill to replace the value instead of appending.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "text": ProgramaToolSchema.string("Text to append."),
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector", "text"]
            )
        ),
        ProgramaTool(
            name: "browser_fill",
            socketMethod: "browser.fill",
            description: "Sets the element matched by a selector to an exact value (replacing any existing value) and fires input/change events. Accepts an empty string to clear the field.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "text": ProgramaToolSchema.string("Value to set. Also accepts value as an alias."),
                    "value": ProgramaToolSchema.string("Alias for text."),
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector", "text"]
            )
        ),
        ProgramaTool(
            name: "browser_press",
            socketMethod: "browser.press",
            description: "Dispatches a keydown, keypress, and keyup for a key to the page's currently focused element (or body if none).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "key": ProgramaToolSchema.string("Key value to dispatch, e.g. 'Enter', 'Tab', 'a'."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["key"]
            )
        ),
        ProgramaTool(
            name: "browser_keydown",
            socketMethod: "browser.keydown",
            description: "Dispatches only a keydown event for a key to the page's currently focused element (or body if none). Use browser_press for a full keydown/keypress/keyup sequence.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "key": ProgramaToolSchema.string("Key value to dispatch."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["key"]
            )
        ),
        ProgramaTool(
            name: "browser_keyup",
            socketMethod: "browser.keyup",
            description: "Dispatches only a keyup event for a key to the page's currently focused element (or body if none).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "key": ProgramaToolSchema.string("Key value to dispatch."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["key"]
            )
        ),
        ProgramaTool(
            name: "browser_check",
            socketMethod: "browser.check",
            description: "Sets a checkbox/radio element matched by a selector to checked, firing input/change events. Fails if the element has no 'checked' property.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_uncheck",
            socketMethod: "browser.uncheck",
            description: "Sets a checkbox/radio element matched by a selector to unchecked, firing input/change events. Fails if the element has no 'checked' property.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_select",
            socketMethod: "browser.select",
            description: "Sets a <select> (or other element with a 'value' property) matched by a selector to a given option value, firing input/change events.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "value": ProgramaToolSchema.string("Option value to select. Also accepts text as an alias."),
                    "text": ProgramaToolSchema.string("Alias for value."),
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector", "value"]
            )
        ),
        ProgramaTool(
            name: "browser_scroll",
            socketMethod: "browser.scroll",
            description: "Scrolls the page (or, if selector is given, a specific scrollable element) by a relative pixel offset.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "dx": ProgramaToolSchema.integer("Horizontal scroll delta in pixels. Defaults to 0."),
                "dy": ProgramaToolSchema.integer("Vertical scroll delta in pixels. Defaults to 0."),
                "selector": ProgramaToolSchema.string("Optional CSS selector of the element to scroll. Defaults to scrolling the window."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_scroll_into_view",
            socketMethod: "browser.scroll_into_view",
            description: "Scrolls the element matched by a selector into the center of the viewport.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_screenshot",
            socketMethod: "browser.screenshot",
            description: "Captures a PNG screenshot of a browser surface's current content. Returns png_base64 (the image, base64-encoded) always, plus a best-effort path/url to a temp-file copy written to disk when the write succeeds.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_get_text",
            socketMethod: "browser.get.text",
            description: "Returns the innerText (falling back to textContent) of the element matched by a selector.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_get_html",
            socketMethod: "browser.get.html",
            description: "Returns the outerHTML of the element matched by a selector.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_get_value",
            socketMethod: "browser.get.value",
            description: "Returns the 'value' property (falling back to textContent) of the element matched by a selector.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_get_attr",
            socketMethod: "browser.get.attr",
            description: "Returns the value of a named attribute on the element matched by a selector (null if the attribute is not present).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "attr": ProgramaToolSchema.string("Attribute name to read. Also accepts name as an alias."),
                    "name": ProgramaToolSchema.string("Alias for attr."),
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector", "attr"]
            )
        ),
        ProgramaTool(
            name: "browser_get_title",
            socketMethod: "browser.get.title",
            description: "Returns a browser surface's current page title.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_get_count",
            socketMethod: "browser.get.count",
            description: "Returns the number of elements matching a selector (document.querySelectorAll(selector).length).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_get_box",
            socketMethod: "browser.get.box",
            description: "Returns the bounding client rect (x, y, width, height, top, left, right, bottom) of the element matched by a selector.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_get_styles",
            socketMethod: "browser.get.styles",
            description: "Returns computed styles for the element matched by a selector: a single property's value when property is given, otherwise a fixed summary (display, visibility, opacity, color, background, width, height).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "property": ProgramaToolSchema.string("Optional single CSS property name to read, e.g. 'color'. Returns a summary object when omitted."),
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_is_visible",
            socketMethod: "browser.is.visible",
            description: "Returns whether the element matched by a selector is visible (not display:none/visibility:hidden/opacity:0, and has a non-zero bounding box).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_is_enabled",
            socketMethod: "browser.is.enabled",
            description: "Returns whether the element matched by a selector is enabled (the inverse of its .disabled property).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_is_checked",
            socketMethod: "browser.is.checked",
            description: "Returns whether the element matched by a selector is checked (false if it has no 'checked' property).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_find_role",
            socketMethod: "browser.find.role",
            description: "Finds the first element with a given ARIA (explicit or implicit) role, optionally filtered by its accessible name. Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "role": ProgramaToolSchema.string("ARIA role to match, e.g. 'button', 'link', 'textbox'. Also accepts value as an alias."),
                    "value": ProgramaToolSchema.string("Alias for role."),
                    "name": ProgramaToolSchema.string("Optional accessible name (aria-label, aria-labelledby text, visible text, or value) to filter by."),
                    "exact": exactProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["role"]
            )
        ),
        ProgramaTool(
            name: "browser_find_text",
            socketMethod: "browser.find.text",
            description: "Finds the first element under <body> whose text content matches (contains, or equals if exact) the given text. Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "text": ProgramaToolSchema.string("Text to search for. Also accepts value as an alias."),
                    "value": ProgramaToolSchema.string("Alias for text."),
                    "exact": exactProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["text"]
            )
        ),
        ProgramaTool(
            name: "browser_find_label",
            socketMethod: "browser.find.label",
            description: "Finds the form control associated with a <label> whose text matches the given label (via the label's 'for' attribute, or the first control nested inside it). Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "label": ProgramaToolSchema.string("Label text to search for. Also accepts text or value as aliases."),
                    "text": ProgramaToolSchema.string("Alias for label."),
                    "value": ProgramaToolSchema.string("Alias for label."),
                    "exact": exactProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["label"]
            )
        ),
        ProgramaTool(
            name: "browser_find_placeholder",
            socketMethod: "browser.find.placeholder",
            description: "Finds the first element whose placeholder attribute matches the given text. Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "placeholder": ProgramaToolSchema.string("Placeholder text to search for. Also accepts text or value as aliases."),
                    "text": ProgramaToolSchema.string("Alias for placeholder."),
                    "value": ProgramaToolSchema.string("Alias for placeholder."),
                    "exact": exactProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["placeholder"]
            )
        ),
        ProgramaTool(
            name: "browser_find_alt",
            socketMethod: "browser.find.alt",
            description: "Finds the first element whose alt attribute matches the given text. Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "alt": ProgramaToolSchema.string("Alt text to search for. Also accepts text or value as aliases."),
                    "text": ProgramaToolSchema.string("Alias for alt."),
                    "value": ProgramaToolSchema.string("Alias for alt."),
                    "exact": exactProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["alt"]
            )
        ),
        ProgramaTool(
            name: "browser_find_title",
            socketMethod: "browser.find.title",
            description: "Finds the first element whose title attribute matches the given text. Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "title": ProgramaToolSchema.string("Title attribute text to search for. Also accepts text or value as aliases."),
                    "text": ProgramaToolSchema.string("Alias for title."),
                    "value": ProgramaToolSchema.string("Alias for title."),
                    "exact": exactProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["title"]
            )
        ),
        ProgramaTool(
            name: "browser_find_testid",
            socketMethod: "browser.find.testid",
            description: "Finds the first element whose data-testid (or data-test-id/data-test) attribute exactly equals the given value. Returns a selector plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "testid": ProgramaToolSchema.string("Test id to match exactly. Also accepts test_id or value as aliases."),
                    "test_id": ProgramaToolSchema.string("Alias for testid."),
                    "value": ProgramaToolSchema.string("Alias for testid."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["testid"]
            )
        ),
        ProgramaTool(
            name: "browser_find_first",
            socketMethod: "browser.find.first",
            description: "Resolves a CSS selector to its first matching element and returns its selector, text, plus an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_find_last",
            socketMethod: "browser.find.last",
            description: "Resolves a CSS selector to its last matching element and returns a specific :nth-of-type selector, text, and an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_find_nth",
            socketMethod: "browser.find.nth",
            description: "Resolves a CSS selector to its Nth matching element (0-based; negative counts from the end) and returns a specific :nth-of-type selector, text, and an element_ref usable by other tools.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "index": ProgramaToolSchema.integer("0-based index into the matches (negative counts from the end). Also accepts nth as an alias."),
                    "nth": ProgramaToolSchema.integer("Alias for index."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector", "index"]
            )
        ),
        ProgramaTool(
            name: "browser_frame_select",
            socketMethod: "browser.frame.select",
            description: "Scopes subsequent selector-based calls on this surface to a same-origin iframe matched by a selector. Fails for cross-origin iframes (WKWebView cannot reach into them). Cleared by browser_frame_main.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_frame_main",
            socketMethod: "browser.frame.main",
            description: "Clears any frame scoping set by browser_frame_select, returning subsequent selector-based calls on this surface to the top-level document.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_dialog_accept",
            socketMethod: "browser.dialog.accept",
            description: "Answers the currently pending native JavaScript dialog (alert/confirm/prompt) on this surface by accepting it. For a prompt(), an optional text sets the answer verbatim, including an empty string; if text is omitted, the page's default prompt text is used. Returns a not_found error if no dialog is pending.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "text": ProgramaToolSchema.string("Text to enter for a prompt() dialog. Also accepts prompt_text as an alias. Ignored for alert/confirm."),
                "prompt_text": ProgramaToolSchema.string("Alias for text."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_dialog_dismiss",
            socketMethod: "browser.dialog.dismiss",
            description: "Answers the currently pending native JavaScript dialog (alert/confirm/prompt) on this surface by canceling it: confirm() resolves to false, prompt() resolves to null. Returns a not_found error if no dialog is pending.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_download_wait",
            socketMethod: "browser.download.wait",
            description: "Waits for a download to complete. With path given, polls that exact file path until it exists and is non-empty. Without path, waits for the next download-completed event on this surface and returns its metadata.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "path": ProgramaToolSchema.string("Exact file path to wait for. If omitted, waits for the next download event on the surface instead."),
                "timeout_ms": ProgramaToolSchema.integer("Maximum time to wait, in milliseconds. Also accepts timeout as an alias. Defaults to 10000."),
                "timeout": ProgramaToolSchema.integer("Alias for timeout_ms."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_cookies_get",
            socketMethod: "browser.cookies.get",
            description: "Returns cookies from the surface's cookie store, optionally filtered by name, domain (substring match), or exact path.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "name": ProgramaToolSchema.string("Filter to cookies with this exact name."),
                "domain": ProgramaToolSchema.string("Filter to cookies whose domain contains this substring."),
                "path": ProgramaToolSchema.string("Filter to cookies with this exact path."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_cookies_set",
            socketMethod: "browser.cookies.set",
            description: "Sets one or more cookies on the surface's cookie store. Provide either a cookies array of cookie objects, or the single-cookie fields (name/value/url/domain/path/secure/expires) directly. domain/url default to the surface's current page when omitted.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "cookies": ["type": "array", "items": ["type": "object"], "description": .string("Array of cookie objects, each with name/value and optionally url/domain/path/secure/expires.")],
                "name": ProgramaToolSchema.string("Cookie name, for setting a single cookie."),
                "value": ProgramaToolSchema.string("Cookie value, for setting a single cookie."),
                "url": ProgramaToolSchema.string("Cookie origin URL, for setting a single cookie. Defaults to the surface's current page."),
                "domain": ProgramaToolSchema.string("Cookie domain, for setting a single cookie. Defaults to the current page's host."),
                "path": ProgramaToolSchema.string("Cookie path, for setting a single cookie. Defaults to '/'."),
                "secure": ProgramaToolSchema.boolean("Mark the cookie Secure, for setting a single cookie."),
                "expires": ProgramaToolSchema.integer("Expiration as a Unix timestamp (seconds), for setting a single cookie. Omit for a session cookie."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_cookies_clear",
            socketMethod: "browser.cookies.clear",
            description: "Removes cookies from the surface's cookie store, optionally filtered by name or domain (substring match). Clears every cookie when no filter and no 'all' flag is given.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "name": ProgramaToolSchema.string("Only clear cookies with this exact name."),
                "domain": ProgramaToolSchema.string("Only clear cookies whose domain contains this substring."),
                "all": ProgramaToolSchema.boolean("Explicitly clear every cookie (same effect as omitting name and domain)."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_storage_get",
            socketMethod: "browser.storage.get",
            description: "Reads from the page's localStorage or sessionStorage. Returns a single value when key is given, or every key/value pair when key is omitted.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "storage": ProgramaToolSchema.stringEnum("Which storage to read. Also accepts type as an alias. Defaults to local.", ["local", "session"]),
                "type": ProgramaToolSchema.stringEnum("Alias for storage.", ["local", "session"]),
                "key": ProgramaToolSchema.string("Storage key to read. Reads every key/value pair when omitted."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_storage_set",
            socketMethod: "browser.storage.set",
            description: "Writes a key/value pair into the page's localStorage or sessionStorage (value is stringified if not already a string).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "storage": ProgramaToolSchema.stringEnum("Which storage to write. Also accepts type as an alias. Defaults to local.", ["local", "session"]),
                    "type": ProgramaToolSchema.stringEnum("Alias for storage.", ["local", "session"]),
                    "key": ProgramaToolSchema.string("Storage key to write."),
                    "value": ["description": .string("Value to store. Strings are stored as-is; other JSON values are stringified.")],
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["key", "value"]
            )
        ),
        ProgramaTool(
            name: "browser_storage_clear",
            socketMethod: "browser.storage.clear",
            description: "Clears every key from the page's localStorage or sessionStorage.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "storage": ProgramaToolSchema.stringEnum("Which storage to clear. Also accepts type as an alias. Defaults to local.", ["local", "session"]),
                "type": ProgramaToolSchema.stringEnum("Alias for storage.", ["local", "session"]),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_tab_new",
            socketMethod: "browser.tab.new",
            description: "Creates a new browser tab (surface) in an existing pane. Never raises/activates the Programa window or switches the selected workspace; inside the target workspace the new tab becomes that pane's focused surface. Returns the new surface_id.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "url": ProgramaToolSchema.string("Initial URL to load. Opens a blank browser tab if omitted."),
                "pane_id": ProgramaToolSchema.string("Pane UUID or short ref to create the tab in. Also accepts target_pane_id as an alias. Defaults to the pane of surface_id, then the workspace's focused pane."),
                "target_pane_id": ProgramaToolSchema.string("Alias for pane_id."),
                "surface_id": ProgramaToolSchema.string("Optional surface UUID or short ref used only to resolve the target pane when pane_id is omitted."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_tab_list",
            socketMethod: "browser.tab.list",
            description: "Lists every browser tab (surface) in a workspace, in display order, with id/title/url/pane/focused state.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_tab_close",
            socketMethod: "browser.tab.close",
            description: "Closes a browser tab (surface). Fails if it would close the workspace's last surface. Target resolves from target_surface_id/tab_id, then index into the workspace's browser tabs, then surface_id, then the workspace's focused surface. Pass workspace_id when the target lives in a workspace other than the selected one; target_surface_id alone does not route the call.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "target_surface_id": ProgramaToolSchema.string("Browser surface UUID or short ref to close. Also accepts tab_id as an alias."),
                "tab_id": ProgramaToolSchema.string("Alias for target_surface_id."),
                "index": ProgramaToolSchema.integer("0-based index into the workspace's browser tabs (in display order), used when target_surface_id/tab_id is omitted."),
                "surface_id": ProgramaToolSchema.string("Fallback target when target_surface_id/tab_id/index are all omitted."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_console_list",
            socketMethod: "browser.console.list",
            description: "Returns console.* messages captured for a browser surface since the page loaded (or since the log was last cleared).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "clear": ProgramaToolSchema.boolean("If true, clear the captured log after reading it. Defaults to false."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_console_clear",
            socketMethod: "browser.console.clear",
            description: "Clears the captured console.* log for a browser surface and returns the entries that were captured up to that point (same response shape as browser_console_list with clear true).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_errors_list",
            socketMethod: "browser.errors.list",
            description: "Returns uncaught JS errors captured for a browser surface since the page loaded (or since the log was last cleared).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "clear": ProgramaToolSchema.boolean("If true, clear the captured error log after reading it. Defaults to false."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_highlight",
            socketMethod: "browser.highlight",
            description: "Briefly (about 1.2s) draws an orange outline around the element matched by a selector, for visually pointing it out. Purely visual; does not click or focus it.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "selector": selectorProperty,
                    "retry_attempts": retryAttemptsProperty,
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["selector"]
            )
        ),
        ProgramaTool(
            name: "browser_state_save",
            socketMethod: "browser.state.save",
            description: "Saves a browser surface's cookies and localStorage/sessionStorage to a JSON file on disk, for later restoring with browser_state_load.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "path": ProgramaToolSchema.string("File path to write the saved state to."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["path"]
            )
        ),
        ProgramaTool(
            name: "browser_state_load",
            socketMethod: "browser.state.load",
            description: "Restores cookies and localStorage/sessionStorage onto a browser surface from a JSON file previously written by browser_state_save. Fails if another restore is already in progress on the same underlying data store.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "path": ProgramaToolSchema.string("File path to read the saved state from."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["path"]
            )
        ),
        ProgramaTool(
            name: "browser_addinitscript",
            socketMethod: "browser.addinitscript",
            description: "Registers a JavaScript source to run at the start of every future document load on this surface (survives navigations), and runs it immediately in the current page too.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "script": ProgramaToolSchema.string("JavaScript source to inject. Also accepts content as an alias."),
                    "content": ProgramaToolSchema.string("Alias for script."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["script"]
            )
        ),
        ProgramaTool(
            name: "browser_addscript",
            socketMethod: "browser.addscript",
            description: "Runs a JavaScript source once in the current page immediately (does not persist across navigations; use browser_addinitscript for that). Returns its result, JSON-normalized.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "script": ProgramaToolSchema.string("JavaScript source to run. Also accepts content as an alias."),
                    "content": ProgramaToolSchema.string("Alias for script."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["script"]
            )
        ),
        ProgramaTool(
            name: "browser_addstyle",
            socketMethod: "browser.addstyle",
            description: "Injects a <style> element with the given CSS into the current page immediately, and registers it to be re-injected at the start of every future document load on this surface (survives navigations).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "css": ProgramaToolSchema.string("CSS source to inject. Also accepts style or content as aliases."),
                    "style": ProgramaToolSchema.string("Alias for css."),
                    "content": ProgramaToolSchema.string("Alias for css."),
                    "surface_id": surfaceIdProperty(),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["css"]
            )
        ),
        ProgramaTool(
            name: "browser_viewport_set",
            socketMethod: "browser.viewport.set",
            description: "Always returns a not_supported error: WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_geolocation_set",
            socketMethod: "browser.geolocation.set",
            description: "Always returns a not_supported error: WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_offline_set",
            socketMethod: "browser.offline.set",
            description: "Always returns a not_supported error: WKWebView does not expose reliable per-tab offline emulation.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_trace_start",
            socketMethod: "browser.trace.start",
            description: "Always returns a not_supported error: Playwright trace artifacts are not available on WKWebView.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_trace_stop",
            socketMethod: "browser.trace.stop",
            description: "Always returns a not_supported error: Playwright trace artifacts are not available on WKWebView.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_network_route",
            socketMethod: "browser.network.route",
            description: "Always returns a not_supported error: WKWebView does not provide CDP-style request interception/mocking. The attempted route is still recorded and shows up in browser_network_requests.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "url": ProgramaToolSchema.string("URL or pattern the route would have matched."),
                "abort": ProgramaToolSchema.boolean("Whether the route would have aborted matching requests."),
                "body": ProgramaToolSchema.string("Response body the route would have returned."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_network_unroute",
            socketMethod: "browser.network.unroute",
            description: "Always returns a not_supported error: WKWebView does not provide CDP-style request interception/mocking. The attempted unroute is still recorded and shows up in browser_network_requests.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "url": ProgramaToolSchema.string("URL or pattern the unroute would have matched."),
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_network_requests",
            socketMethod: "browser.network.requests",
            description: "Always returns a not_supported error, along with recorded_requests: the browser_network_route/browser_network_unroute attempts recorded for this surface (WKWebView cannot supply real request logs).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": surfaceIdProperty(),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "browser_screencast_start",
            socketMethod: "browser.screencast.start",
            description: "Always returns a not_supported error: WKWebView does not expose CDP screencast streaming. Use browser_screenshot for point-in-time captures.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_screencast_stop",
            socketMethod: "browser.screencast.stop",
            description: "Always returns a not_supported error: WKWebView does not expose CDP screencast streaming.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_input_mouse",
            socketMethod: "browser.input_mouse",
            description: "Always returns a not_supported error: raw CDP mouse injection is unavailable. Use browser_click/browser_hover/browser_scroll instead.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_input_keyboard",
            socketMethod: "browser.input_keyboard",
            description: "Always returns a not_supported error: raw CDP keyboard injection is unavailable. Use browser_press/browser_keydown/browser_keyup instead.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_input_touch",
            socketMethod: "browser.input_touch",
            description: "Always returns a not_supported error: raw CDP touch injection is unavailable on WKWebView.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "browser_design_mode_toggle",
            socketMethod: "browser.design_mode.toggle",
            description: "Toggles Design Mode on the workspace's focused browser panel (or its single browser panel, when a terminal is focused). Inside that workspace it focuses the browser panel and its web view; it never raises/activates the Programa window or switches the selected workspace. No surface_id needed.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
    ]
}
