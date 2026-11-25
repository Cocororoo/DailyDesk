const $ = (s, root = document) => root.querySelector(s);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const names = {Genshin:'原神', StarRail:'星穹铁道', Endfield:'终末地'};
const latin = {Genshin:'GENSHIN IMPACT',StarRail:'HONKAI: STAR RAIL',Endfield:'ARKNIGHTS: ENDFIELD'};
const days = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
const dayNames = ['一','二','三','四','五','六','日'];
const paths = {
  layout:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  sliders:'<path d="M4 7h5m5 0h6M4 17h10m5 0h1"/><circle cx="11" cy="7" r="2.5"/><circle cx="16" cy="17" r="2.5"/>',
  history:'<path d="M3 11a9 9 0 1 1 2 7M3 4v7h7m2-5v6l4 2"/>',
  refresh:'<path d="M20 7a9 9 0 0 0-15-2L2 8m0-6v6h6M4 17a9 9 0 0 0 15 2l3-3m0 6v-6h-6"/>',
  play:'<path d="m8 4 12 8-12 8z"/>', check:'<path d="m5 12 4 4L19 6"/>',
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  chevron:'<path d="m9 5 7 7-7 7"/>', arrow:'<path d="M4 12h16m-6-6 6 6-6 6"/>',
  shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',
  stop:'<rect x="5" y="5" width="14" height="14" rx="2"/>',
  info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10v.1"/>',
  warning:'<path d="m12 3 10 18H2zM12 9v4m0 4v.1"/>',
  target:'<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="4"/><path d="m12 12 8-8m-2-1h3v3"/>',
  leaf:'<path d="M5 19c-3-9 2-14 14-14 0 11-5 17-14 14Zm0 0L15 9m-5 5v-4m0 4h4"/>',
  orbit:'<circle cx="12" cy="12" r="3"/><ellipse cx="12" cy="12" rx="11" ry="5" transform="rotate(-35 12 12)"/><path d="m7 4 1 3m9 10 1 3"/>',
  cube:'<path d="m12 2 9 5v10l-9 5-9-5V7zM3 7l9 5 9-5M12 12v10m-5-17 10 6"/>',
  external:'<path d="M14 3h7v7m0-7L11 13m-1-9H4v16h16v-6"/>',
  save:'<path d="M4 3h13l4 4v14H3V3m4 0v6h10V3M7 21v-8h10v8"/>',
  close:'<path d="m6 6 12 12M6 18 18 6"/>',
  terminal:'<path d="m5 6 5 5-5 5m8 0h6"/>',
  folder:'<path d="M3 7V4h6l3 3h9v13H3z"/>',
  list:'<path d="M8 6h13M8 12h13M8 18h13M3 6h.1M3 12h.1M3 18h.1"/>',
  download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v4a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-4"/>',
};
const icon = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name]||paths.info}</svg>`;
const gameLogo = game => icon({Genshin:"leaf", StarRail:"orbit", Endfield:"cube"}[game]);
const emblem = game => `<span class="game-emblem ${game}">${gameLogo(game)}</span>`;
function hydrateIcons(root = document) {root.querySelectorAll('[data-icon]').forEach(e => e.innerHTML = icon(e.dataset.icon));}
hydrateIcons();
let config, draft, status, runs = [], token, dirty = false, saving = false, selected = 'Genshin', currentDetail;
let updateStatus, updateRequest = false;
let filters = {query:'',game:'All',status:'All'};
let toastTimer;
const main = $('#main');
const route = () => location.hash.slice(1).split('/')[0] || 'overview';
const success = run => typeof run==='object' ? run.display?.state==='completed' : run==='native_sequence_completed_requires_reward_review';
const label = run => run.display ? [run.display.title,run.display.kind] : run==='cancelled'||run.status==='cancelled' ? ['已中止','failed'] : ['running','preparing'].includes(run.status||run) ? ['运行中','running'] : run==='unreadable'||run.status==='unreadable' ? ['记录缺失','warning'] : ['未完成','warning'];
const badge = (text,kind='') => `<span class="status-tag ${kind}"><i></i>${esc(text)}</span>`;
const dtf = (value, options = {}) => value ? new Date(value).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false,...options}) : '—';
function duration(start, end) {if (!start || !end) return '—'; const seconds=Math.max(0,Math.round((new Date(end)-new Date(start))/1000));return seconds<60?`${seconds} 秒`:`${Math.floor(seconds/60)} 分 ${seconds%60} 秒`;}
const today = () => status.gameDay;
function toast(text,error=false){const box=$('#toast');box.textContent=text;box.className=`visible${error?' error':''}`;clearTimeout(toastTimer);toastTimer=setTimeout(()=>box.className='',error?6500:3500);}
async function api(path,body){const response=await fetch('/api/'+path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json','X-Daily-Token':token}:{},body:body?JSON.stringify(body):undefined});const result=await response.json();if(!response.ok)throw Error(result.error||'操作未完成');return result;}
function connection(ok){const c=$('#connection');c.innerHTML=`<i></i>${ok?'本机已连接':'连接已中断'}`;c.classList.toggle('offline',!ok);}
function todayStages(){const map={};for(const run of runs){if(run.gameDay!==today())continue;for(const stage of run.stages||[]){if(!map[stage.Game]){const result=run.display?.games.find(g=>g.id===stage.Game);map[stage.Game]={...stage,result,runId:run.id};}}}return map;}
function gameStatus(game){const stage=todayStages()[game];if(!stage)return ['今日未运行',''];if(stage.result)return [stage.result.label,stage.result.kind];return stage.NativeCompleted?['已完成','success']:['未完成','warning'];}
function gameResult(game){const stage=todayStages()[game];if(!stage?.result)return '';return `<button class="game-result ${stage.result.kind}" data-run="${esc(stage.runId)}" aria-label="查看${names[game]}运行结果">${icon(stage.result.state==='completed'?'check':'warning')}<span>${esc(stage.result.summary)}</span>${icon('chevron')}</button>`;}
function target(game){const g=config.games[game];if(game==='Genshin')return g.domain;if(game==='StarRail')return g.target;return config.catalog.Endfield.find(l=>l.value===g.location)?.label||g.location;}
function activeBanner(){if(status.active){const active=status.active, terminal=!!active.finishedAt;const stage=active.stages.find(s=>s.Status==='running');return `<div class="notice"><span class="progress-dot"></span><p>${terminal?'本轮已结束，监督窗口仍打开':`正在执行 ${esc(stage?names[stage.Game]:'日常流程')}`}<br><small>${terminal?'关闭窗口后即可启动新任务或保存配置。':'停止会保留本轮记录，并回收本轮游戏与助手进程。'}</small></p><button class="btn" data-stop="${esc(active.id)}">${icon(terminal?'close':'stop')}${terminal?'关闭已结束窗口':'停止任务'}</button></div>`;}
  if(status.updating)return `<div class="notice"><span class="spinner"></span><p>正在更新自动化软件</p><a class="btn" href="#updates">查看进度 ${icon('chevron')}</a></div>`;
  if(status.pending)return `<div class="notice"><span class="spinner"></span><p>正在打开${status.pending.game==='All'?'每日上班':esc(names[status.pending.game])}，如出现系统权限提示，请在本机确认。</p></div>`;
  if(status.processes.length)return `<div class="notice warning">${icon('info')}<p>检测到游戏或助手已打开：${status.processes.map(p=>esc(p.name)).join('、')}。完全退出后即可开始新任务或保存计划。</p></div>`;
  if(status.launchError)return `<div class="notice warning">${icon('warning')}<p>${esc(status.launchError)}</p></div>`;return '';}
function heading(eyebrow,title,sub,actions=''){return `<div class="page-heading"><div>${eyebrow?`<div class="eyebrow">${eyebrow}</div>`:''}<h1>${title}</h1><p class="subtext">${sub}</p></div><div class="heading-actions">${actions}</div></div>`;}
function runButton(game,primary=false){return `<button class="btn ${primary?'primary':''}" data-launch="${game}" ${status.busy?'disabled':''}>${icon('play')}${game==='All'?'运行全部':'运行'}</button>`;}
function render(){if(!config)return;const page=route();document.querySelectorAll('[data-nav]').forEach(a=>a.classList.toggle('active',a.dataset.nav===page));$('#page-label').textContent={overview:'总览',plans:'任务计划',history:'运行记录',about:'关于控制台',updates:'软件更新'}[page]||'总览';$('#history-count').textContent=runs.length;main.innerHTML=page==='plans'?plans():page==='history'?history():page==='about'?about():page==='updates'?updates():overview();}
function overview(){
 const done=Object.values(todayStages()).filter(s=>s.result?.state==='completed').length;
 const recent=runs[0];
 const attention=runs.filter(r=>r.gameDay===today()&&!success(r)&&r.finishedAt).length;
 return heading('','日常总览','',`<span class="date-label">${new Date().toLocaleDateString('zh-CN',{month:'long',day:'numeric',weekday:'long'})}</span>${runButton('All',true)}`)+activeBanner()+`
 <div class="daily-summary"><div class="today-progress">${icon('check')}<span>今日完成 <strong>${done} / 3</strong></span>${attention?`<a href="#history" class="attention-link">${attention} 次有未完成项 ${icon('chevron')}</a>`:''}</div><div class="latest-status">${recent?`<span>最近运行 ${dtf(recent.startedAt)} · ${duration(recent.startedAt,recent.finishedAt)}</span><button class="text-button" data-run="${esc(recent.id)}">查看详情 ${icon('chevron')}</button>`:'尚无运行记录'}</div></div>
 <div class="game-grid">${Object.keys(names).map(game=>gameCard(game)).join('')}</div>
 <section class="panel recent-panel"><div class="panel-header"><h2>最近运行</h2><a href="#history">全部记录 ${icon('arrow')}</a></div><div class="history-mini">${runs.slice(0,3).map(r=>miniRun(r)).join('')||'<div class="empty">暂无运行记录</div>'}</div></section>`;
}
function gameCard(game){
 const g=config.games[game];
 const details={Genshin:[['一条龙',config.profile]],StarRail:[['副本类型',g.type]],Endfield:[['特产采集',g.tasks.AutoCollect?((g.days||[]).map(d=>'周'+dayNames[days.indexOf(d)]).join('、')||'未安排'):'已关闭'],['物资保留',g.tasks.AutoStockStaple?`${(g.reserve/10000).toLocaleString()} 万`:'采购已关闭']]}[game];
 return `<article class="game-card" aria-label="${names[game]}日常"><div class="game-card-top">${emblem(game)}<div class="game-title"><h2>${names[game]}</h2></div>${badge(...gameStatus(game))}</div><div class="game-body"><div class="target-box"><div class="target-label">${icon('target')}${game==='Endfield'?'源质地区':'体力副本'}</div><div class="target-name">${esc(target(game))}</div></div><dl class="key-settings">${details.map(([k,v])=>`<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>${gameResult(game)}</div><div class="game-actions"><button class="btn" data-plan="${game}" aria-label="${names[game]}任务设置">${icon('sliders')}任务设置</button>${runButton(game)}</div></article>`;
}
function miniRun(r){const [text,kind]=label(r);return `<button class="mini-run" data-run="${esc(r.id)}" aria-label="查看 ${esc(dtf(r.startedAt))} 的运行记录"><span class="run-symbol ${kind==='success'?'':'failed'}">${icon(kind==='success'?'check':kind==='running'?'clock':'info')}</span><span class="mini-run-info"><span class="mini-run-title">${r.games.length===3?'三游戏日常':r.games.map(g=>names[g]).join(' / ')||'日常记录'}</span></span><span class="mini-run-time">${dtf(r.startedAt)}</span><span class="mini-run-duration">${duration(r.startedAt,r.finishedAt)}</span>${badge(text,kind)}${icon('chevron')}</button>`;}

const assistantNames = {Genshin:'BetterGI', StarRail:'三月七小助手', Endfield:'MaaEnd'};
const updateLabels = {
  available:['有新版本','warning'], current:['已是最新版','success'],
  updated:['更新完成','success'], failed:['更新失败','failed'],
};
const updatePhases = {checking:'正在检查版本',downloading:'正在下载',extracting:'正在解压',installing:'正在安装和验证'};

function updates() {
  if (!updateStatus) return heading('', '软件更新', '') + '<p class="loading">正在读取版本…</p>';
  const {games, operation} = updateStatus;
  const busy = updateRequest || !!operation;
  const running = operation
    ? `<div class="notice" role="status"><span class="spinner"></span><p>${operation.game ? esc(assistantNames[operation.game])+' · ' : ''}${esc(updatePhases[operation.phase])}</p></div>`
    : activeBanner();
  const actions = `<button class="btn" data-update="check" data-game="All" ${busy?'disabled':''}>${icon('refresh')}检查更新</button>
    <button class="btn primary" data-update="install" data-game="All" ${busy||status.busy?'disabled':''}>${icon('download')}全部更新</button>`;
  const rows = Object.entries(games).map(([game, item]) => {
    const [result, kind] = updateLabels[item.state] || ['未检查', ''];
    return `<article class="update-row">
      <div class="update-name">${emblem(game)}<div><h2>${assistantNames[game]}</h2><span>${names[game]}</span></div></div>
      <dl class="update-versions"><div><dt>当前版本</dt><dd>${esc(item.installed || '未知')}</dd></div><div><dt>最新稳定版</dt><dd>${esc(item.latest || '—')}</dd></div></dl>
      <div class="update-result">${badge(result, kind)}
        ${item.message ? `<small>${esc(item.message)}</small>` : item.checkedAt ? `<small>${dtf(item.checkedAt)} 检查</small>` : ''}
      </div>
      <div class="update-controls">
        <label class="update-toggle"><span>自动更新</span><span class="switch">
          <input type="checkbox" data-auto-update="${game}" aria-label="${assistantNames[game]}自动更新" ${item.auto?'checked':''} ${busy?'disabled':''}><span></span>
        </span></label>
        <button class="btn" data-update="install" data-game="${game}" aria-label="更新 ${assistantNames[game]}" ${busy||status.busy?'disabled':''}>${icon('download')}更新</button>
      </div>
    </article>`;
  });
  return heading('', '软件更新', '稳定版 · 本机空闲时自动更新', actions) + running
    + `<section class="update-list" aria-label="自动化软件">${rows.join('')}</section>`;
}

async function loadUpdates() {
  const previous = updateStatus;
  updateStatus = await api('updates');
  if (route() === 'updates' && JSON.stringify(previous) !== JSON.stringify(updateStatus)) render();
}

async function runUpdate(action, game) {
  if (updateRequest) return;
  updateRequest = true;
  render();
  try {
    await api('updates', {action, game});
    await loadUpdates();
  } catch (error) {
    toast(error.message, true);
  } finally {
    updateRequest = false;
    render();
  }
}

async function toggleUpdate(event) {
  const control = event.target;
  if (!control.dataset.autoUpdate) return;
  updateRequest = true;
  const enabled = control.checked;
  render();
  try {
    updateStatus = await api('updates/auto', {game:control.dataset.autoUpdate, enabled});
    toast(enabled ? '已开启自动更新' : '已关闭自动更新');
  } catch (error) {
    toast(error.message, true);
  } finally {
    updateRequest = false;
    render();
  }
}
main.addEventListener('change', toggleUpdate);
main.addEventListener('click', event => {
  const button = event.target.closest('[data-update]');
  if (button) runUpdate(button.dataset.update, button.dataset.game);
});
function options(list,value){return list.map(d=>`<option value="${esc(d.value)}" ${d.value===value?'selected':''}>${esc(d.label)}${d.description?' · '+esc(d.description):''}</option>`).join('');}
function switchRow(game,key,labelText,fixed=false){return `<div class="switch-row"><span class="switch-label">${esc(labelText)}${fixed?'<small>固定日常任务</small>':''}</span><label class="switch"><input type="checkbox" aria-label="${esc(labelText)}" data-task="${esc(key)}" data-game="${game}" ${fixed||draft[game].tasks[key]?'checked':''} ${fixed?'disabled':''}><span></span></label></div>`;}
function field(title,content,help=''){return `<div class="field"><label>${title}</label>${content}${help?`<small>${help}</small>`:''}</div>`;}
function section(number,title,sub,body){return `<section class="panel form-section"><div class="form-title"><span class="step">${number}</span><div><h2>${title}</h2><p>${sub}</p></div></div>${body}</section>`;}
function plans(modal=false){const hashGame=location.hash.split('/')[1];if(!modal&&hashGame in names)selected=hashGame;const g=draft[selected];let body='';if(selected==='Genshin'){
 const groups=[...new Set(config.catalog.Genshin.map(d=>d.group))];const opts=groups.map(group=>`<optgroup label="${group}">${options(config.catalog.Genshin.filter(d=>d.group===group).map(d=>({...d,label:d.label+' · '+d.region})),g.domain)}</optgroup>`).join('');
 body=section('01','体力使用',config.nativeGenshinDomain?'选择 BetterGI 支持的秘境。':'自定义秘境脚本的目标在 BetterGI 中设置。',config.nativeGenshinDomain?field('刷取秘境',`<select aria-label="原神刷取秘境" data-field="domain" data-game="Genshin">${opts}</select>`,'仅列出本机 BetterGI 支持的圣遗物、天赋与武器材料秘境。材料本按当天开放情况执行。')+field('周日材料组',`<select aria-label="周日材料组" data-field="sunday" data-game="Genshin">${['1','2','3'].map(v=>`<option ${g.sunday===v?'selected':''} value="${v}">第 ${v} 组</option>`).join('')}</select>`,'仅材料秘境在周日生效，按游戏内从左到右的顺序选择；圣遗物秘境忽略此项。'):'')+
 section('02','每日任务','切换一条龙中的附加任务。',Object.entries(config.taskLabels.Genshin).map(([k,v])=>switchRow('Genshin',k,v)).join(''));
 }else if(selected==='StarRail'){
 body=section('01','开拓力使用','选择三月七助手支持的副本。',field('副本类型',`<select aria-label="星铁副本类型" data-field="type" data-game="StarRail">${['侵蚀隧洞','饰品提取'].map(v=>`<option ${g.type===v?'selected':''}>${v}</option>`).join('')}</select>`)+field('刷取副本',`<select aria-label="星铁刷取副本" data-field="target" data-game="StarRail">${options(config.catalog.StarRail[g.type],g.target)}</select>`,'按自然开拓力持续挑战；饰品提取会一并使用已有沉浸器。'))+
 section('02','每日任务','清体力、补足每日实训并领奖为固定流程。',switchRow('StarRail','core-power','清开拓力',true)+switchRow('StarRail','core-daily','每日实训与 500 活跃度领奖',true)+Object.entries(config.taskLabels.StarRail).map(([k,v])=>switchRow('StarRail',k,v)).join(''));
 }else{
 body=section('01','源质与物资','设置源质地区与采购保留线。',field('源质地区',`<select aria-label="终末地源质地区" data-field="location" data-game="Endfield">${options(config.catalog.Endfield,g.location)}</select>`,'原生随机模式，仅选择此地区。')+`<div class="field-row">${field('循环上限',`<input aria-label="源质循环上限" type="number" min="1" max="99" data-field="repeat" data-game="Endfield" value="${g.repeat}">`,'体力不足会提前结束。')}${field('调度券保留线（万）',`<input aria-label="调度券保留线（万）" type="number" min="0" max="214748.3647" step="0.0001" data-field="reserve" data-game="Endfield" value="${g.reserve/10000}">`,'购买前余额低于此值，不再购买稳定物资。')}</div>`)+
 section('02','特产采集与存仓','按 MaaEnd 的每周计划执行。',field('执行星期',`<div class="weekdays">${days.map((day,i)=>`<label class="day-check"><input aria-label="周${dayNames[i]}采集" type="checkbox" data-day="${day}" ${g.days.includes(day)?'checked':''}><span>周${dayNames[i]}</span></label>`).join('')}</div>`,'非安排日由 MaaEnd 自动跳过，不会启动采集路线。')+`<div class="switch-row"><span class="switch-label">采集前后自动存放背包<small>采集中途存仓可在 MaaEnd 中设置。</small></span><label class="switch"><input aria-label="采集前后自动存仓" type="checkbox" data-field="stash" data-game="Endfield" ${g.stash?'checked':''}><span></span></label></div>`)+
 section('03','每日任务','选择要在原生计划中运行的任务。',Object.entries(config.taskLabels.Endfield).map(([k,v])=>switchRow('Endfield',k,v)).join(''));
 }
 const notes={Genshin:['BetterGI 一条龙','队伍和战斗策略在 BetterGI 中设置'],StarRail:['三月七小助手日常','日常完成后退出游戏'],Endfield:['MaaEnd 原生日常','采集路线和道具使用在 MaaEnd 中设置']}[selected];
 const prefix=modal?'':heading('','任务计划','保存后，下次运行生效。')+activeBanner()+`<div class="tabs" role="tablist">${Object.entries(names).map(([game,name])=>`<button class="tab ${game===selected?'active':''}" role="tab" aria-selected="${game===selected}" data-tab="${game}">${gameLogo(game)}${name}</button>`).join('')}</div>`;return prefix+`<div class="plan-layout"><div><fieldset ${status.busy?'disabled':''}>${body}</fieldset></div><aside class="panel plan-aside"><h3>当前运行设置</h3>${notes.map(n=>`<div class="aside-row"><strong>${n}</strong></div>`).join('')}<div class="aside-note"><b>保存后，下一次启动生效。</b><br>保存前自动备份。运行时不可修改配置。<br><br>${selected==='Genshin'?'委托领奖需要当日进度足够；只清树脂不一定能补满四份奖励。':selected==='Endfield'?'保留线按购买前余额判断，最后一笔购买后可能低于设定值。':'仅显示当前助手已支持的副本；新副本请先更新原生助手。'}</div></aside></div><div class="savebar"><p id="save-state">${dirty?'配置未保存':'配置已保存'}</p><div class="actions"><button class="btn" id="discard" ${!dirty?'disabled':''}>放弃修改</button><button class="btn primary" id="save" ${!dirty||saving||status.busy?'disabled':''}>${icon('save')}${saving?'正在保存…':'保存计划'}</button></div></div>`;
}
function renderPlanModal(){
 if(!$('#plan-dialog').open)return;
 $('#plan-dialog-heading').innerHTML=`${emblem(selected)}<div><h2 id="plan-dialog-title">${names[selected]} · 任务设置</h2><p>保存后，下次运行生效。</p></div>`;
 $('#plan-dialog-content').innerHTML=plans(true);
 $('#plan-dialog-footer').replaceChildren($('#plan-dialog-content .savebar'));
 $('#close-plan').disabled=saving;
}
function openPlan(game){selected=game;$('#plan-dialog').showModal();renderPlanModal();$('#plan-dialog-content').scrollTop=0;}
async function closePlan(){
 if(saving)return;
 if(dirty){if(!await ask('放弃未保存的修改？','关闭设置将放弃尚未保存的修改。','放弃修改'))return;draft=structuredClone(config.games);dirty=false;}
 $('#plan-dialog').close();render();
}
$('#close-plan').addEventListener('click',closePlan);
$('#plan-dialog').addEventListener('cancel',e=>{e.preventDefault();closePlan();});
function filteredRuns(){return runs.filter(r=>(filters.game==='All'||r.games.includes(filters.game))&&(filters.status==='All'||(filters.status==='success'?success(r):filters.status==='attention'?!success(r)&&!!r.finishedAt:r.status==='cancelled'))&&`${r.id} ${r.summary} ${r.games.map(g=>names[g])}`.toLowerCase().includes(filters.query.toLowerCase()));}
function history(){return heading('','运行记录','查看历次任务结果、日志与证据。')+activeBanner()+`<div class="filter-bar"><input class="filter-input" id="history-search" aria-label="搜索运行记录" placeholder="搜索记录或异常信息…" value="${esc(filters.query)}"><select class="filter-select" id="history-game" aria-label="按游戏筛选"><option value="All">所有游戏</option>${Object.entries(names).map(([k,v])=>`<option value="${k}" ${filters.game===k?'selected':''}>${v}</option>`).join('')}</select><select class="filter-select" id="history-status" aria-label="按结果筛选">${[['All','所有结果'],['success','已完成'],['attention','未完成'],['cancelled','已中止']].map(([k,v])=>`<option value="${k}" ${filters.status===k?'selected':''}>${v}</option>`).join('')}</select><span class="count" id="filtered-count">共 ${filteredRuns().length} 条记录</span></div><section class="panel table-wrap"><table class="records-table"><thead><tr><th>运行时间</th><th>任务范围</th><th>用时</th><th>运行结果</th><th></th></tr></thead><tbody id="records-body">${historyRows()}</tbody></table></section>`;}
function historyRows(){const found=filteredRuns();return found.map(r=>{const [text,kind]=label(r);return `<tr data-run="${esc(r.id)}" tabindex="0" role="button" aria-label="查看 ${esc(dtf(r.startedAt))} 的运行记录"><td><span class="record-name">${dtf(r.startedAt)}</span><small>${esc(r.id)}</small></td><td>${r.games.length===3?'三游戏每日上班':r.games.map(g=>names[g]).join(' / ')||'日常记录'}<small>${r.games.map(g=>names[g]).join(' → ')}</small></td><td>${duration(r.startedAt,r.finishedAt)}</td><td>${badge(text,kind)}${r.display?.alerts?.length?`<small class="record-alert">${esc(r.display.alerts.map(a=>(names[a.game]||'')+' · '+a.task).join('；'))}</small>`:''}</td><td>${icon('chevron')}</td></tr>`;}).join('')||'<tr><td colspan="5"><div class="empty">'+icon('history')+'没有匹配的运行记录，试试其他筛选条件。</div></td></tr>';}
function about(){return heading('','关于','每日上班控制台 · v1.0')+`<section class="panel form-section"><h2>使用说明</h2><p class="aside-note">Run-Daily.cmd 可直接启动三游戏日常。这里保存的计划写入同一份原生配置，不需要先打开控制台；浏览器关闭后，已启动的日常仍由独立监督窗口管理。<br>「停止任务」调用同一个监督窗口，保留日志并回收本轮子进程。登录、首次声明和系统权限提示仍在本机处理。<br>任务按完成、已执行、跳过和失败显示；“已执行”表示有操作记录。掉落数量和原始判定在详情中查看，历史失败记录保留。</p></section><div class="section-line"><h2>设计参考</h2><span class="subtext">借鉴成熟开源项目的组织方式</span></div><div class="about-grid">${[
 ['shadcn/ui','侧栏、表单与统一间距。','https://github.com/shadcn-ui/ui'],
 ['Homepage','服务卡片与状态汇总。','https://github.com/gethomepage/homepage'],
 ['Dockge','配置、启动与运行日志。','https://github.com/louislam/dockge']
 ].map(([name,desc,url])=>`<section class="panel reference-card"><h3>${name}</h3><p>${desc}</p><a href="${url}" target="_blank" rel="noreferrer">开源项目 ${icon('external')}</a></section>`).join('')}</div><section class="panel form-section about-path"><h2>本机数据位置</h2><div class="aside-note">${Object.entries(config.paths).map(([g,p])=>`${names[g]}：${esc(p)}`).join('<br>')}<br>总调度与历史：${esc(status.root)}<br>仅监听 127.0.0.1，不上传游戏日志或配置。</div></section>`;}
function updateDirty(){dirty=JSON.stringify(draft)!==JSON.stringify(config.games);const b=$('#save');if(b)b.disabled=!dirty||saving||status.busy;const d=$('#discard');if(d)d.disabled=!dirty;const p=$('#save-state');if(p)p.textContent=dirty?'配置未保存':'配置已保存';}
function capture(event){const el=event.target;if(el.dataset.field){const game=el.dataset.game;let value=el.type==='checkbox'?el.checked:el.type==='number'?Number(el.value):el.value;if(el.dataset.field==='reserve')value=Math.round(value*10000);draft[game][el.dataset.field]=value;if(el.dataset.field==='type'){draft.StarRail.target=config.catalog.StarRail[value][0].value;render();renderPlanModal();}}
 if(el.dataset.task)draft[el.dataset.game].tasks[el.dataset.task]=el.checked;
 if(el.dataset.day)draft.Endfield.days=days.filter(d=>d===el.dataset.day?el.checked:draft.Endfield.days.includes(d));
 updateDirty();
 if(el.id==='history-search'){filters.query=el.value;$('#records-body').innerHTML=historyRows();$('#filtered-count').textContent=`共 ${filteredRuns().length} 条记录`;}
 if(el.id==='history-game'||el.id==='history-status'){filters[el.id==='history-game'?'game':'status']=el.value;$('#records-body').innerHTML=historyRows();$('#filtered-count').textContent=`共 ${filteredRuns().length} 条记录`;}
}
main.addEventListener('input',capture);main.addEventListener('change',capture);$('#plan-dialog').addEventListener('input',capture);$('#plan-dialog').addEventListener('change',capture);
async function save(){if(saving||!dirty)return;try{saving=true;render();renderPlanModal();const result=await api('config',{revision:config.revision,games:draft});config=result.configuration;draft=structuredClone(config.games);dirty=false;$('#plan-dialog').close();toast('已保存，下次运行生效。');}catch(e){toast(e.message,true);}finally{saving=false;render();renderPlanModal();}}
function ask(title,text,button='确认启动'){const dialog=$('#confirm-dialog');$('#confirm-title').textContent=title;$('#confirm-text').textContent=text;$('#confirm-go').textContent=button;dialog.showModal();return new Promise(resolve=>{const go=()=>{cleanup();dialog.close();resolve(true);};const cancel=()=>{cleanup();dialog.close();resolve(false);};const cleanup=()=>{$('#confirm-go').removeEventListener('click',go);$('#confirm-cancel').removeEventListener('click',cancel);dialog.removeEventListener('cancel',cancel);};$('#confirm-go').addEventListener('click',go);$('#confirm-cancel').addEventListener('click',cancel);dialog.addEventListener('cancel',cancel);});}
async function launch(game){if(dirty){toast('请先保存或放弃任务计划的修改。',true);return;}const todayDone=Object.values(todayStages()).filter(s=>s.NativeCompleted&& (game==='All'||s.Game===game)).length;const title=game==='All'?'运行全部':'运行'+names[game]+'日常';const text=(todayDone?'今天已有相关游戏的成功记录。再次运行仍会检查奖励并使用可用体力。\n\n':'')+(game==='All'?Object.keys(names).map(g=>names[g]+' · '+target(g)).join('\n'):names[game]+' · '+target(game))+'\n\n运行期间请保持游戏前台，避免操作键鼠。';if(todayDone&&!await ask(title,text))return;try{await api('launch',{game});status=await api('status');render();toast('已发送启动请求，请处理可能出现的系统权限提示。');}catch(e){toast(e.message,true);}}
async function stop(runId){const terminal=!!status.active?.finishedAt;if(!terminal&&!await ask('停止本轮日常？','将停止后续游戏，并关闭本轮游戏与助手。已生成的记录会保留。','停止并保留记录'))return;try{const result=await api('stop',{runId});toast(result.message);}catch(e){toast(e.message,true);}}
function evidenceLink(runId,row){return row.Evidence&&/\.(json|log|txt|md|png|jpg)$/i.test(row.Evidence)?`<a href="/api/evidence?run=${encodeURIComponent(runId)}&path=${encodeURIComponent(row.Evidence)}" target="_blank" rel="noreferrer">原始证据 ${icon('external')}</a>`:'';}
function resultRow(task,runId){return `<details class="result-task"><summary><span class="result-task-name">${esc(task.title)}</span>${badge(task.label,task.kind)}<span class="result-task-summary">${esc(task.summary)}</span>${icon('chevron')}</summary><div class="result-evidence"><p>${esc(task.raw.Detail||'任务记录已保存')}</p>${evidenceLink(runId,task.raw)}</div></details>`;}
async function openRun(runId){try{
 const detail=await api('runs/'+encodeURIComponent(runId));currentDetail=runId;
 const r=detail.run,d=detail.display;const [text,kind]=label(r);
 $('#dialog-content').innerHTML=`<div class="dialog-header"><div><h2 id="dialog-title">${r.games.length===3?'三游戏日常':r.games.map(g=>names[g]).join(' / ')} ${badge(text,kind)}</h2><p>${dtf(r.startedAt)} · ${duration(r.startedAt,r.finishedAt)}</p></div><button class="icon-btn" id="close-detail" aria-label="关闭运行详情">${icon('close')}</button></div><div class="dialog-content result-content"><div class="result-overview"><div><strong>${d.completedGames} / ${d.gameCount}</strong><span>游戏已完成</span></div><button class="btn" data-open-record="${esc(runId)}">${icon('folder')}记录目录</button></div>${d.alerts.length?`<section class="result-alerts" aria-label="未完成项目"><h3>${icon('warning')}未完成项目</h3>${d.alerts.map(a=>`<div><strong>${esc(names[a.game]||'运行记录')} · ${esc(a.task)}</strong><span>${esc(a.message)}</span></div>`).join('')}</section>`:`<p class="result-ok">${icon(d.state==='completed'?'check':'info')}${esc(d.summary)}</p>`}
 ${d.games.map(game=>`<details class="result-game" ${['incomplete','failed','running'].includes(game.state)?'open':''}><summary><span class="result-game-title">${emblem(game.id)}${game.name}</span><span class="result-counts">${game.counts.completed?`${game.counts.completed} 完成`:''}${game.counts.executed?` · ${game.counts.executed} 执行`:''}${game.counts.skipped?` · ${game.counts.skipped} 跳过`:''}</span>${badge(game.label,game.kind)}${icon('chevron')}</summary><div class="result-rows">${game.tasks.map(t=>resultRow(t,runId)).join('')||'<p class="empty">没有任务记录</p>'}</div></details>`).join('')}
 <details class="technical-details"><summary>${icon('info')}详细记录与日志 ${icon('chevron')}</summary><p class="evidence-note">完成表示原生任务完成；已执行表示已记录操作。物品数量未单独统计。</p>${d.games.map(game=>game.notes.length?`<details class="raw-notes"><summary>${game.name} · 补充记录</summary>${game.notes.map(row=>`<div class="result-evidence"><strong>${esc(row.Task)}</strong><p>${esc(row.Detail)}</p>${evidenceLink(runId,row)}</div>`).join('')}</details>`:'').join('')}<details class="raw-notes"><summary>原始运行判定</summary><p class="result-evidence">${esc(detail.report.Summary||r.status)}${r.error?'<br>'+esc(r.error):''}</p></details><div class="log-title">${icon('terminal')}最近日志<button class="btn ghost" data-reload-detail="${esc(runId)}">刷新</button></div><pre class="log">${esc(detail.log)}</pre></details></div>`;
 if(!$('#detail-dialog').open)$('#detail-dialog').showModal();$('#close-detail').onclick=()=>$('#detail-dialog').close();
 }catch(e){toast(e.message,true);}}
$('#detail-dialog').addEventListener('click',e=>{const button=e.target.closest('button');if(button?.dataset.reloadDetail)openRun(button.dataset.reloadDetail);if(button?.dataset.openRecord)api('open-record',{runId:button.dataset.openRecord}).catch(e=>toast(e.message,true));});
async function handleClick(e){const button=e.target.closest('button,a,[data-run]');if(!button)return;if(button.dataset.plan)return openPlan(button.dataset.plan);if(button.dataset.launch)return launch(button.dataset.launch);if(button.dataset.stop)return stop(button.dataset.stop);if(button.dataset.run)return openRun(button.dataset.run);if(button.dataset.tab){selected=button.dataset.tab;location.hash='plans/'+selected;render();}if(button.id==='save')save();if(button.id==='discard'){draft=structuredClone(config.games);dirty=false;render();renderPlanModal();}}
main.addEventListener('click',handleClick);$('#plan-dialog').addEventListener('click',handleClick);
main.addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)&&e.target.dataset.run){e.preventDefault();openRun(e.target.dataset.run);}});
window.addEventListener('hashchange', () => {
  render();
  if (route() === 'updates') loadUpdates().catch(error => toast(error.message, true));
});
window.addEventListener('beforeunload',e=>{if(dirty){e.preventDefault();e.returnValue='';}});
async function refresh(manual=false){
  try {
    const wasBusy = status?.busy;
    const wasUpdating = status?.updating;
    const [next, history, software] = await Promise.all([api('status'), api('runs'), api('updates')]);
    const softwareChanged = JSON.stringify(updateStatus) !== JSON.stringify(software);
    status = next;
    runs = history.runs;
    updateStatus = software;
    connection(true);
    if (manual || (wasUpdating && !status.updating)) {
      const fresh = await api('bootstrap');
      token = fresh.token;
      if (!dirty) {
        config = fresh.configuration;
        draft = structuredClone(config.games);
      }
    }
    const page = route();
    const editingFilter = page === 'history' && document.activeElement?.matches('input,select');
    if (page === 'updates' ? softwareChanged || manual || wasBusy !== status.busy
      : (page !== 'plans' && !editingFilter) || manual || wasBusy !== status.busy) render();
    if ($('#plan-dialog').open && (manual || wasBusy !== status.busy)) renderPlanModal();
    if (manual) toast('已刷新本机状态。');
  } catch (e) {
    connection(false);
    if (manual) toast(e.message,true);
  }
}
$('#refresh').addEventListener('click',()=>refresh(true));
async function boot(){try{const [data,history,software]=await Promise.all([api('bootstrap'),api('runs'),api('updates')]);token=data.token;config=data.configuration;draft=structuredClone(config.games);status=data.status;runs=history.runs;updateStatus=software;connection(true);render();setInterval(()=>refresh(),5000);}catch(e){connection(false);main.innerHTML=`<div class="empty">${icon('warning')}读取本机数据失败：${esc(e.message)}<br>点击右上角刷新重试。</div>`;$('#refresh').onclick=boot;}}
boot();
