import{g,C as u,p as w,a as y}from"./chunks/diff-vendor.mjs";import"./chunks/shiki-core.mjs";import"./chunks/preload-helper.mjs";import"./chunks/pierre-theming.mjs";const k=new Set(["c","cpp","cpp-macro","css","glsl","go","html","javascript","json","jsonc","jsx","markdown","python","regexp","rust","shellscript","swift","toml","tsx","typescript","yaml","zig"]),S=new Set([...k,"bash","sh","shell","yml","zsh"]);function d(e){window.webkit?.messageHandlers?.programaReview?.postMessage(e)}const c=document.getElementById("root");if(!c)throw new Error("Missing #root");const b=new URLSearchParams(location.search).get("style")==="unified"?"unified":"split",L=g({poolOptions:{poolSize:2,workerFactory:()=>new Worker(new URL("/chunks/diff-worker.mjs",location.href),{type:"module"})},highlighterOptions:{langs:["text"],preferredHighlighter:"shiki-wasm",lineDiffType:"word",maxLineDiffLength:1e3,tokenizeMaxLineLength:1e3,useTokenTransformer:!1}});function x(e,t){if(t.item.type!=="diff")return;const r=e.side??"additions",o=e.endSide??r;r!=="additions"||o!=="additions"||d({type:"selectLines",filePath:t.item.fileDiff.name,side:"additions",startLine:Math.min(e.start,e.end),endLine:Math.max(e.start,e.end)})}function l(e){return{theme:{dark:"pierre-dark",light:"pierre-light"},themeType:"system",diffStyle:e,diffIndicators:"bars",overflow:"scroll",lineDiffType:"word",maxLineDiffLength:1e3,tokenizeMaxLineLength:1e3,lineHoverHighlight:"number",enableLineSelection:!0,enableGutterUtility:!0,stickyHeaders:!0,layout:{paddingTop:0,gap:1,paddingBottom:16},unsafeCSS:v,onGutterUtilityClick:x}}const v=`
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
`;let s=b;const n=new u(l(s),L);n.setup(c);let f=0;function M(e,t){const r=[],o=new Map;for(const m of w(e,t))for(const i of m.files){const h=y(i.name);S.has(h)||(i.lang="text");const a=o.get(i.name)??0;o.set(i.name,a+1),r.push({id:a===0?i.name:`${i.name}#${a}`,type:"diff",fileDiff:i,version:f})}return r}async function p(){const e=++f;try{const t=await fetch("/patch",{cache:"no-store"});if(!t.ok)throw new Error(`patch request failed: ${t.status}`);const r=await t.text();if(e!==f)return;n.setItems(M(r,`review-${e}`)),n.render()}catch(t){d({type:"error",message:String(t?.stack??t)})}}window.programaReview={reload:p,setDiffStyle(e){e!==s&&(s=e,n.setOptions(l(s)),n.render())}};window.addEventListener("error",e=>d({type:"error",message:String(e.message)}));p();
