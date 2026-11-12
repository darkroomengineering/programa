import{a as e,c as t,i as n,r}from"./chunks/diff-vendor.mjs";var i=new Set([...new Set([`c`,`cpp`,`cpp-macro`,`css`,`glsl`,`go`,`html`,`javascript`,`json`,`jsonc`,`jsx`,`markdown`,`python`,`regexp`,`rust`,`shellscript`,`swift`,`toml`,`tsx`,`typescript`,`yaml`,`zig`]),`bash`,`sh`,`shell`,`yml`,`zsh`]);function a(e){window.webkit?.messageHandlers?.programaReview?.postMessage(e)}var o=document.getElementById(`root`);if(!o)throw Error(`Missing #root`);var s=new URLSearchParams(location.search).get(`style`)===`unified`?`unified`:`split`,c=r({poolOptions:{poolSize:2,workerFactory:()=>new Worker(new URL(`/chunks/diff-worker.mjs`,location.href),{type:`module`})},highlighterOptions:{langs:[`text`],preferredHighlighter:`shiki-wasm`,lineDiffType:`word`,maxLineDiffLength:1e3,tokenizeMaxLineLength:1e3,useTokenTransformer:!1}});function l(e,t){if(t.item.type!==`diff`)return;let n=e.side??`additions`,r=e.endSide??n;n===`additions`&&r===`additions`&&a({type:`selectLines`,filePath:t.item.fileDiff.name,side:`additions`,startLine:Math.min(e.start,e.end),endLine:Math.max(e.start,e.end)})}function u(e){return{theme:{dark:`pierre-dark`,light:`pierre-light`},themeType:`system`,diffStyle:e,diffIndicators:`bars`,overflow:`scroll`,lineDiffType:`word`,maxLineDiffLength:1e3,tokenizeMaxLineLength:1e3,lineHoverHighlight:`number`,enableLineSelection:!0,enableGutterUtility:!0,stickyHeaders:!0,layout:{paddingTop:0,gap:1,paddingBottom:16},unsafeCSS:d,onGutterUtilityClick:l}}var d=`
  :host {
    --diffs-light-bg: transparent;
    --diffs-dark-bg: transparent;
    --diffs-bg-context-override: transparent;
    --diffs-bg-context-gutter-override: transparent;
    --diffs-bg-separator-override: transparent;
    --diffs-font-family: ui-monospace, "SF Mono", Menlo, monospace;
    --diffs-font-size: 12px;
  }
  :host, pre, code { background-color: transparent; }
  [data-diffs-header] {
    background-color: color-mix(in srgb, Canvas 70%, transparent) !important;
    -webkit-backdrop-filter: blur(8px);
    backdrop-filter: blur(8px);
  }
`,f=s,p=new n(u(f),c);p.setup(o);var m=0;function h(n,r){let a=[],o=new Map;for(let s of e(n,{cacheKeyPrefix:r}))for(let e of s.files){let n=t(e.name);i.has(n)||(e.lang=`text`);let r=o.get(e.name)??0;o.set(e.name,r+1),a.push({id:r===0?e.name:`${e.name}#${r}`,type:`diff`,fileDiff:e,version:m})}return a}async function g(){let e=++m;try{let t=await fetch(`/patch`,{cache:`no-store`});if(!t.ok)throw Error(`patch request failed: ${t.status}`);let n=await t.text();if(e!==m)return;p.setItems(h(n,`review-${e}`)),p.render()}catch(e){a({type:`error`,message:String(e?.stack??e)})}}window.programaReview={reload:g,setDiffStyle(e){e!==f&&(f=e,p.setOptions(u(f)),p.render())}},window.addEventListener(`error`,e=>a({type:`error`,message:String(e.message)})),g();