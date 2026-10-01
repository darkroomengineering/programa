// Body of the browser.snapshot collector. TerminalController.v2BrowserSnapshotJavaScript
// wraps it in an IIFE that first declares the __interactiveOnly ... __nonContentTextTags
// constants, so this file must not redeclare them.

  const __byteWidth = (codePoint) => codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
  const __boundedUTF8 = (input, limit, normalizeWhitespace = false) => {
    const source = String(input == null ? '' : input);
    let value = '';
    let bytes = 0;
    let truncated = false;
    let pendingSpace = false;
    let inspected = 0;
    for (const character of source) {
      inspected += 1;
      if (normalizeWhitespace && inspected > (limit * 4 + 256)) {
        truncated = true;
        break;
      }
      if (normalizeWhitespace && /\s/u.test(character)) {
        if (value) pendingSpace = true;
        continue;
      }
      const width = __byteWidth(character.codePointAt(0));
      const spaceWidth = pendingSpace ? 1 : 0;
      if (bytes + spaceWidth + width > limit) {
        truncated = true;
        break;
      }
      if (pendingSpace) {
        value += ' ';
        bytes += 1;
        pendingSpace = false;
      }
      value += character;
      bytes += width;
    }
    return { value, bytes, truncated };
  };
  const __htmlLocalName = (element, byteLimit = 64) => {
    if (!element || element.namespaceURI !== __htmlNamespace) return null;
    const bounded = __boundedUTF8(element.localName || '', byteLimit);
    if (!bounded.value || bounded.truncated) return null;
    return bounded.value.toLowerCase();
  };

  const __title = __boundedUTF8(document.title || '', __titleByteLimit);
  const __url = __boundedUTF8(document.location?.href || '', __urlByteLimit);
  if (__title.truncated) __reasons.add('title_byte_limit');
  if (__url.truncated) __reasons.add('url_byte_limit');

  let __root = document.body || document.documentElement;
  let __scoped = false;
  if (__scopeSelector) {
    try {
      const boundedScope = __boundedUTF8(__scopeSelector, __selectorByteLimit);
      if (!boundedScope.truncated && boundedScope.value) {
        const scopedRoot = document.querySelector(boundedScope.value);
        if (scopedRoot) {
          __root = scopedRoot;
          __scoped = true;
        }
      }
    } catch (_) {}
  }
  const __serializationRoot = __scoped ? __root : (document.documentElement || __root);
  const __entries = [];
  const __seenSelectors = new Set();
  const __pathByElement = new WeakMap();
  const __elementChildrenSeenByParent = new WeakMap();
  let __entryBytes = 0;
  let __visitedNodes = 0;
  let __workNodes = 0;
  let __nodeBudgetExhausted = false;
  let __selectorSkippedCount = 0;
  let __nameTruncatedCount = 0;
  let __roleSkippedCount = 0;
  let __stop = false;
  let __scopeDepth = __scoped ? 0 : null;
  let __scopeActive = __scoped;

  const __chargeNodeWork = () => {
    if (__workNodes >= __nodeLimit) {
      __nodeBudgetExhausted = true;
      __reasons.add('node_limit');
      return false;
    }
    __workNodes += 1;
    return true;
  };

  let __text = '';
  let __textTruncated = false;
  let __textInspectedUnits = 0;
  let __textInspectionExhausted = false;
  let __textAuthoredWhitespace = false;
  let __textSeparatorRequested = false;
  let __textOutputStopped = false;
  const __markTextInspectionExhausted = () => {
    __textInspectionExhausted = true;
    __textTruncated = true;
    __reasons.add('text_inspection_limit');
  };
  const __inspectTextSource = (value, consume) => {
    if (__textInspectionExhausted || value == null) return { truncated: __textInspectionExhausted, stopped: false };
    const source = String(value);
    let index = 0;
    while (index < source.length) {
      const codePoint = source.codePointAt(index);
      const character = String.fromCodePoint(codePoint);
      const units = character.length;
      if (__textInspectedUnits > __textInspectionLimit - units) {
        __markTextInspectionExhausted();
        return { truncated: true, stopped: false };
      }
      __textInspectedUnits += units;
      index += units;
      if (consume(character) === false) return { truncated: false, stopped: true };
    }
    return { truncated: false, stopped: false };
  };
  const __requestTextSeparator = () => {
    if (__text) __textSeparatorRequested = true;
  };
  const __appendText = (value) => {
    if (__textOutputStopped || __textInspectionExhausted || !value) return;
    __inspectTextSource(value, (character) => {
      if (/\s/u.test(character)) {
        if (__text) __textAuthoredWhitespace = true;
        return true;
      }
      const needsSpace = __text && (__textAuthoredWhitespace || __textSeparatorRequested);
      const required = character.length + (needsSpace ? 1 : 0);
      if (__text.length > __textLimit - required) {
        __textTruncated = true;
        __textOutputStopped = true;
        return false;
      }
      if (needsSpace) __text += ' ';
      __text += character;
      __textAuthoredWhitespace = false;
      __textSeparatorRequested = false;
      return true;
    });
  };

  let __html = '';
  let __htmlTruncated = false;
  let __htmlStopped = false;
  let __attributeCount = 0;
  const __appendHTML = (value) => {
    if (__htmlStopped || !value) return;
    const remaining = __htmlLimit - __html.length;
    if (remaining <= 0) { __htmlTruncated = true; __htmlStopped = true; return; }
    const source = String(value);
    __html += source.slice(0, remaining);
    if (source.length > remaining) { __htmlTruncated = true; __htmlStopped = true; }
  };
  const __appendEscapedHTML = (value, attribute) => {
    if (__htmlStopped) return;
    const source = String(value == null ? '' : value);
    const remaining = Math.max(0, __htmlLimit - __html.length);
    const probe = source.slice(0, remaining + 1);
    const needsEscaping = attribute ? /[&<>"]/u.test(probe) : /[&<>]/u.test(probe);
    if (!needsEscaping) {
      __appendHTML(source);
      return;
    }
    for (const character of source) {
      let escaped = character;
      if (character === '&') escaped = '&amp;';
      else if (character === '<') escaped = '&lt;';
      else if (character === '>') escaped = '&gt;';
      else if (attribute && character === '"') escaped = '&quot;';
      __appendHTML(escaped);
      if (__htmlStopped) return;
    }
  };
  const __appendBoundedHTMLName = (rawName, lowercase) => {
    if (__htmlStopped) return;
    const remaining = __htmlLimit - __html.length;
    if (remaining <= 0) { __htmlTruncated = true; __htmlStopped = true; return; }
    const source = String(rawName || '');
    const boundedSource = source.slice(0, remaining + 1);
    __appendHTML(lowercase ? boundedSource.toLowerCase() : boundedSource);
    if (!__htmlStopped && source.length > boundedSource.length) {
      __htmlTruncated = true;
      __htmlStopped = true;
    }
  };
  const __descriptorByElement = new WeakMap();
  const __elementDescriptor = (element) => {
    const cached = __descriptorByElement.get(element);
    if (cached) return cached;
    const isHTML = element.namespaceURI === __htmlNamespace;
    const local = __boundedUTF8(element.localName || '', 64);
    const descriptor = {
      isHTML,
      semanticLocal: isHTML && !local.truncated ? local.value.toLowerCase() : null,
      prefix: element.prefix || '',
      localName: element.localName || ''
    };
    __descriptorByElement.set(element, descriptor);
    return descriptor;
  };
  const __appendElementName = (element) => {
    const descriptor = __elementDescriptor(element);
    if (descriptor.prefix) {
      __appendBoundedHTMLName(descriptor.prefix, false);
      __appendHTML(':');
    }
    __appendBoundedHTMLName(descriptor.localName, descriptor.isHTML);
  };
  const __appendAttributeName = (attribute) => {
    if (attribute.prefix) {
      __appendBoundedHTMLName(attribute.prefix, false);
      __appendHTML(':');
      __appendBoundedHTMLName(attribute.localName, false);
    } else {
      __appendBoundedHTMLName(attribute.name || attribute.localName, false);
    }
  };
  const __appendOpenTag = (element) => {
    if (__htmlStopped) return;
    __appendHTML('<');
    __appendElementName(element);
    if (__htmlStopped) return;
    const attributes = element.attributes;
    for (let index = 0; index < attributes.length; index += 1) {
      if (__attributeCount >= __attributeLimit) {
        __htmlTruncated = true;
        __htmlStopped = true;
        return;
      }
      __attributeCount += 1;
      const attribute = attributes.item(index);
      if (!attribute) continue;
      __appendHTML(' ');
      __appendAttributeName(attribute);
      __appendHTML('=');
      __appendHTML('"');
      __appendEscapedHTML(attribute.value, true);
      __appendHTML('"');
      if (__htmlStopped) return;
    }
    __appendHTML('>');
  };
  const __appendCloseTag = (element) => {
    if (__htmlStopped) return;
    const descriptor = __elementDescriptor(element);
    if (descriptor.isHTML && descriptor.semanticLocal && __voidTags.has(descriptor.semanticLocal)) return;
    __appendHTML('<');
    __appendHTML('/');
    __appendElementName(element);
    if (!__htmlStopped) __appendHTML('>');
  };

  const __implicitRole = (element) => {
    const tag = __htmlLocalName(element, 64);
    if (!tag) return null;
    if (tag === 'button' || tag === 'summary') return 'button';
    if (tag === 'a' && element.hasAttribute('href')) return 'link';
    if (tag === 'input') {
      const type = __boundedUTF8(element.getAttribute('type') || 'text', 32, true).value.toLowerCase();
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
      return 'textbox';
    }
    if (tag === 'textarea') return 'textbox';
    if (tag === 'select') return 'combobox';
    if (/^h[1-6]$/.test(tag)) return 'heading';
    if (tag === 'li') return 'listitem';
    return null;
  };
  const __styleByElement = new WeakMap();
  const __computedStyleFor = (element) => {
    if (__styleByElement.has(element)) return __styleByElement.get(element);
    try {
      const view = element.ownerDocument?.defaultView;
      const style = view?.getComputedStyle ? view.getComputedStyle(element) : null;
      __styleByElement.set(element, style);
      return style;
    } catch (_) {
      __styleByElement.set(element, null);
      return null;
    }
  };
  const __isVisible = (element) => {
    try {
      const style = __computedStyleFor(element);
      const rect = element.getBoundingClientRect();
      return !!style && !!rect && rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0.01;
    } catch (_) { return false; }
  };
  const __cursorEligible = (element) => {
    if (!__includeCursor) return false;
    try {
      const style = __computedStyleFor(element);
      const tabIndex = element.getAttribute('tabindex');
      return typeof element.onclick === 'function' || element.hasAttribute('onclick') || style?.cursor === 'pointer' || (tabIndex != null && String(tabIndex) !== '-1');
    } catch (_) { return false; }
  };
  const __isRenderedBlock = (element) => {
    const tag = __htmlLocalName(element, 64);
    if (tag === 'br') return true;
    const display = __computedStyleFor(element)?.display || '';
    return !!display && display !== 'none' && display !== 'contents' && !display.startsWith('inline');
  };
  const __isOwnTextSuppressed = (element, ignoreHidden = false) => {
    const tag = __htmlLocalName(element, 64);
    if (tag && __nonContentTextTags.has(tag)) return true;
    if (ignoreHidden) return false;
    if (element.hidden || element.hasAttribute('hidden')) return true;
    const ariaHidden = __boundedUTF8(element.getAttribute('aria-hidden') || '', 16, true).value.toLowerCase();
    if (ariaHidden === 'true') return true;
    const style = __computedStyleFor(element);
    return style?.display === 'none' || style?.visibility === 'hidden' || style?.visibility === 'collapse';
  };
  const __templateHostByContent = new WeakMap();
  const __textSuppressedByElement = new WeakMap();
  const __updateTextSuppression = (element) => {
    const domParent = element.parentNode;
    const logicalParent = __templateHostByContent.get(domParent) || domParent;
    const parentSuppressed = logicalParent ? (__textSuppressedByElement.get(logicalParent) || false) : false;
    const suppressed = parentSuppressed || __isOwnTextSuppressed(element);
    __textSuppressedByElement.set(element, suppressed);
    return suppressed;
  };

  const __createNameSink = () => ({
    value: '', bytes: 0, pendingWhitespace: false, separatorRequested: false,
    truncated: false, stopped: false
  });
  const __appendNameCharacter = (sink, character) => {
    if (sink.stopped) return false;
    if (/\s/u.test(character)) {
      if (sink.value) sink.pendingWhitespace = true;
      return true;
    }
    const needsSpace = sink.value && (sink.pendingWhitespace || sink.separatorRequested);
    const width = __byteWidth(character.codePointAt(0));
    const required = width + (needsSpace ? 1 : 0);
    if (sink.bytes > __nameByteLimit - required) {
      sink.truncated = true;
      sink.stopped = true;
      return false;
    }
    if (needsSpace) { sink.value += ' '; sink.bytes += 1; }
    sink.value += character;
    sink.bytes += width;
    sink.pendingWhitespace = false;
    sink.separatorRequested = false;
    return true;
  };
  const __appendNameSource = (sink, value) => {
    if (sink.stopped || !value) return;
    const inspected = __inspectTextSource(value, (character) => __appendNameCharacter(sink, character));
    if (inspected.truncated) return;
  };
  const __mergeNameValue = (sink, result) => {
    if (!result.value) {
      if (result.truncated) sink.truncated = true;
      return;
    }
    if (sink.value) sink.separatorRequested = true;
    for (const character of result.value) {
      if (!__appendNameCharacter(sink, character)) break;
    }
    if (result.truncated) sink.truncated = true;
  };
  const __nameContentCache = new WeakMap();
  const __explicitLabelContentCache = new WeakMap();
  const __walkNameContent = (root, includeHiddenSubtree) => {
    const cache = includeHiddenSubtree ? __explicitLabelContentCache : __nameContentCache;
    const cached = cache.get(root);
    if (cached) return cached;
    const sink = __createNameSink();
    const suppressedByElement = new WeakMap();
    let node = root;
    while (node) {
      if (!__chargeNodeWork()) break;
      let suppressed = false;
      if (node.nodeType === Node.ELEMENT_NODE) {
        const parentSuppressed = node === root ? false : (suppressedByElement.get(node.parentElement) || false);
        suppressed = parentSuppressed || __isOwnTextSuppressed(node, includeHiddenSubtree);
        suppressedByElement.set(node, suppressed);
        if (!suppressed && __isRenderedBlock(node)) sink.separatorRequested = !!sink.value;
      } else if (node.nodeType === Node.TEXT_NODE) {
        suppressed = suppressedByElement.get(node.parentElement) || false;
        if (!suppressed) __appendNameSource(sink, node.nodeValue || '');
      }

      const descend = node.nodeType === Node.ELEMENT_NODE && !suppressed && !!node.firstChild;
      if (descend) {
        node = node.firstChild;
        continue;
      }
      while (node) {
        if (node.nodeType === Node.ELEMENT_NODE
            && !(suppressedByElement.get(node) || false)
            && __isRenderedBlock(node)
            && sink.value) {
          sink.separatorRequested = true;
        }
        if (node === root) { node = null; break; }
        if (node.nextSibling) { node = node.nextSibling; break; }
        node = node.parentNode;
      }
    }
    const result = { value: sink.value, bytes: sink.bytes, truncated: sink.truncated };
    cache.set(root, result);
    return result;
  };
  const __boundedNameSource = (value) => __boundedUTF8(value || '', __nameByteLimit, true);
  const __nameFor = (element) => {
    let result = null;
    let discoveryTruncated = false;
    const labelledBy = __boundedUTF8(element.getAttribute('aria-labelledby') || '', 256, true);
    if (labelledBy.value) {
      const combined = __createNameSink();
      const resolvedLabels = new Set();
      let count = 0;
      for (const id of labelledBy.value.split(' ')) {
        if (!id) continue;
        if (count >= 16) { combined.truncated = true; break; }
        count += 1;
        const labelled = element.ownerDocument?.getElementById(id);
        if (!labelled || resolvedLabels.has(labelled)) continue;
        resolvedLabels.add(labelled);
        __mergeNameValue(combined, __walkNameContent(labelled, true));
        if (combined.stopped || __nodeBudgetExhausted) break;
      }
      discoveryTruncated = labelledBy.truncated || combined.truncated;
      if (combined.value) result = { value: combined.value, bytes: combined.bytes, truncated: combined.truncated };
    } else {
      discoveryTruncated = labelledBy.truncated;
    }
    if (!result) {
      const ariaLabel = __boundedNameSource(element.getAttribute('aria-label') || '');
      if (ariaLabel.value) result = ariaLabel;
      discoveryTruncated = discoveryTruncated || ariaLabel.truncated;
    }
    const tag = __htmlLocalName(element, 64);
    if (!result && (tag === 'input' || tag === 'textarea')) {
      const hostName = __boundedNameSource(element.getAttribute('placeholder') || element.value || '');
      if (hostName.value) result = hostName;
      discoveryTruncated = discoveryTruncated || hostName.truncated;
    }
    if (!result) {
      const titleName = __boundedNameSource(element.getAttribute('title') || '');
      if (titleName.value) result = titleName;
      discoveryTruncated = discoveryTruncated || titleName.truncated;
    }
    if (!result) result = __walkNameContent(element, false);
    if (result.truncated || discoveryTruncated) {
      __nameTruncatedCount += 1;
      __reasons.add('name_byte_limit');
    }
    return result;
  };

  const __buildScopedRootPath = (element) => {
    const documentElement = element.ownerDocument?.documentElement;
    let current = element;
    let suffix = '';
    while (current) {
      if (!__chargeNodeWork()) return null;
      if (current === documentElement) {
        const complete = __boundedUTF8(':root' + suffix, __selectorByteLimit);
        return complete.truncated ? null : complete.value;
      }
      const parent = current.parentElement;
      if (!parent) return null;
      let ordinal = 1;
      let sibling = current.previousElementSibling;
      while (sibling) {
        if (!__chargeNodeWork()) return null;
        ordinal += 1;
        sibling = sibling.previousElementSibling;
      }
      const candidate = ' > :nth-child(' + ordinal + ')' + suffix;
      if (__boundedUTF8(candidate, __selectorByteLimit).truncated) return null;
      suffix = candidate;
      current = parent;
    }
    return null;
  };
  let __scopedPathAvailable = !__scoped;
  if (__scoped) {
    const scopedPath = __buildScopedRootPath(__root);
    if (scopedPath) {
      __pathByElement.set(__root, scopedPath);
      __scopedPathAvailable = true;
    }
  }
  const __recordStructuralPath = (element) => {
    const existing = __pathByElement.get(element);
    if (existing) return existing;
    if (__scoped && element === __root && !__scopedPathAvailable) return null;
    if (element === element.ownerDocument?.documentElement) {
      __pathByElement.set(element, ':root');
      return ':root';
    }
    const parent = element.parentElement;
    if (!parent) return null;
    const ordinal = (__elementChildrenSeenByParent.get(parent) || 0) + 1;
    __elementChildrenSeenByParent.set(parent, ordinal);
    const parentPath = __pathByElement.get(parent);
    if (!parentPath) return null;
    const candidate = parentPath + ' > :nth-child(' + ordinal + ')';
    const bounded = __boundedUTF8(candidate, __selectorByteLimit);
    if (bounded.truncated) return null;
    __pathByElement.set(element, bounded.value);
    return bounded.value;
  };
  const __selectorFor = (element) => {
    const structural = __pathByElement.get(element) || null;
    const rawId = element.id || '';
    if (rawId) {
      const rawBound = __boundedUTF8(rawId, __selectorByteLimit);
      if (rawBound.truncated) return { selector: null, oversized: true };
      try {
        const escapedValue = __boundedUTF8(CSS.escape(rawBound.value), __selectorByteLimit - 1);
        if (escapedValue.truncated) return { selector: null, oversized: true };
        const escaped = '#' + escapedValue.value;
        if (element.ownerDocument?.querySelector(escaped) === element) {
          return { selector: escaped, oversized: false };
        }
      } catch (_) {}
    }
    return { selector: structural, oversized: !structural };
  };

  const __appendEntry = (element, depth) => {
    if (!__isVisible(element)) return;
    const cursorEligible = __cursorEligible(element);
    const explicitRaw = element.getAttribute('role') || '';
    const explicitBounded = __boundedUTF8(explicitRaw, __roleByteLimit, true);
    const explicitValue = explicitBounded.value.toLowerCase();
    const explicitRole = !explicitBounded.truncated && __allowedRoles.has(explicitValue) ? explicitValue : null;
    const implicitRole = __implicitRole(element);
    let role = explicitRole || implicitRole || (cursorEligible ? 'generic' : null);
    if (!role) {
      if (explicitRaw) { __roleSkippedCount += 1; __reasons.add('role_byte_limit'); }
      return;
    }
    if (__interactiveOnly && !__interactiveRoles.has(role) && !cursorEligible) return;
    if (!__interactiveOnly && !__interactiveRoles.has(role) && !__contentRoles.has(role) && !cursorEligible) return;
    const selectorResult = __selectorFor(element);
    if (!selectorResult.selector) {
      if (selectorResult.oversized) { __selectorSkippedCount += 1; __reasons.add('selector_byte_limit'); }
      return;
    }
    const name = __nameFor(element);
    if (__compact && role === 'generic' && !name.value) return;
    const selector = selectorResult.selector;
    if (__seenSelectors.has(selector)) return;
    if (__entries.length >= __entryLimit) { __reasons.add('entry_limit'); __stop = true; return; }
    const candidateBytes = __boundedUTF8(selector, __selectorByteLimit).bytes + name.bytes + __boundedUTF8(role, __roleByteLimit).bytes;
    if (candidateBytes > __entryByteLimit - __entryBytes) { __reasons.add('entry_byte_limit'); __stop = true; return; }
    __seenSelectors.add(selector);
    __entryBytes += candidateBytes;
    __entries.push({ selector, role, name: name.value, depth });
  };

  const __firstTraversalChild = (node) => {
    if (node.nodeType === Node.ELEMENT_NODE) {
      const descriptor = __elementDescriptor(node);
      if (descriptor.isHTML && descriptor.semanticLocal === 'template') {
        const content = node.content;
        if (content) {
          __templateHostByContent.set(content, node);
          __textSuppressedByElement.set(
            content,
            __textSuppressedByElement.get(node) || false
          );
          return content.firstChild;
        }
      }
    }
    return node.firstChild;
  };
  const __traversalParent = (node) => {
    const domParent = node.parentNode;
    return __templateHostByContent.get(domParent) || domParent;
  };

  let __node = __serializationRoot;
  let __depth = 0;
  while (__node && !__stop) {
    if (!__chargeNodeWork()) {
      __textTruncated = true;
      __htmlTruncated = true;
      break;
    }
    __visitedNodes += 1;
    const isElement = __node.nodeType === Node.ELEMENT_NODE;
    if (__node === __root) {
      __scopeDepth = __depth;
      __scopeActive = true;
    }
    const inScope = __scopeActive;
    const relativeDepth = __scopeDepth == null ? 0 : __depth - __scopeDepth;
    let textSuppressed = false;
    if (isElement) {
      textSuppressed = __updateTextSuppression(__node);
      __appendOpenTag(__node);
      __recordStructuralPath(__node);
    }
    else if (__node.nodeType === Node.TEXT_NODE) {
      const parentDescriptor = __node.parentElement ? __elementDescriptor(__node.parentElement) : null;
      if (parentDescriptor?.isHTML
          && parentDescriptor.semanticLocal
          && __rawTextTags.has(parentDescriptor.semanticLocal)) {
        __appendHTML(__node.nodeValue || '');
      }
      else __appendEscapedHTML(__node.nodeValue || '', false);
    } else if (__node.nodeType === Node.COMMENT_NODE) {
      __appendHTML('<!--');
      __appendHTML(__node.nodeValue || '');
      __appendHTML('-->');
    }

    if (inScope) {
      if (isElement && !textSuppressed) {
        if (__isRenderedBlock(__node)) __requestTextSeparator();
      }
      if (__node.nodeType === Node.TEXT_NODE) {
        const domParent = __node.parentNode;
        const parent = __templateHostByContent.get(domParent) || domParent;
        if (!parent || !(__textSuppressedByElement.get(parent) || false)) {
          __appendText(__node.nodeValue || '');
        }
      }
      if (isElement && relativeDepth <= __maxDepth) __appendEntry(__node, relativeDepth);
      if (__stop || __nodeBudgetExhausted) {
        __textTruncated = true;
        __htmlTruncated = true;
        break;
      }
    }

    const firstChild = __firstTraversalChild(__node);
    let descend = !!firstChild;
    if (inScope && relativeDepth >= __maxDepth && descend) {
      descend = false;
      __textTruncated = true;
      __htmlTruncated = true;
      __htmlStopped = true;
    }
    if (descend) {
      __node = firstChild;
      __depth += 1;
      continue;
    }
    while (__node) {
      if (__node.nodeType === Node.ELEMENT_NODE) {
        const closingSuppressed = __textSuppressedByElement.get(__node) || false;
        if (__scopeActive && !closingSuppressed && __isRenderedBlock(__node)) {
          __requestTextSeparator();
        }
        __appendCloseTag(__node);
        if (__node === __root) __scopeActive = false;
      }
      if (__node === __serializationRoot) { __node = null; break; }
      if (__node.nextSibling) { __node = __node.nextSibling; break; }
      __node = __traversalParent(__node);
      __depth -= 1;
    }
  }

  const __truncationReasons = __reasonOrder.filter((reason) => __reasons.has(reason));
  return {
    title: __title.value,
    url: __url.value,
    ready_state: String(document.readyState || ''),
    text: __text,
    html: __html,
    entries: __entries,
    truncated: __truncationReasons.length > 0 || __textTruncated || __htmlTruncated,
    truncation_reasons: __truncationReasons,
    element_limit: __entryLimit,
    node_limit: __nodeLimit,
    visited_nodes: __visitedNodes,
    text_inspection_limit: __textInspectionLimit,
    text_inspected_units: __textInspectedUnits,
    entry_byte_limit: __entryByteLimit,
    entry_bytes: __entryBytes,
    selector_byte_limit: __selectorByteLimit,
    selector_skipped_count: __selectorSkippedCount,
    name_byte_limit: __nameByteLimit,
    name_truncated_count: __nameTruncatedCount,
    role_byte_limit: __roleByteLimit,
    role_skipped_count: __roleSkippedCount,
    title_byte_limit: __titleByteLimit,
    url_byte_limit: __urlByteLimit,
    text_truncated: __textTruncated,
    html_truncated: __htmlTruncated
  };
