#!/usr/bin/env node
/**
 * Zentao pro8.2 stdio MCP server
 *
 * 适配禅道专业版 8.2（≈开源 12.x，无 REST API）：
 *  - 通道: index.php?m=<module>&f=<method>&t=json（官方 PHP SDK 同源方案）
 *  - 登录: GET 登录页取 verifyRand → password = md5(md5(pw)+rand) → POST + keepLogin
 *  - 会话: 内存维护 zentaosid/za/zp cookie，检测到登录跳转自动重登
 *
 * 环境变量:
 *  ZENTAO_URL       例 http://192.168.1.212/index.php
 *  ZENTAO_ACCOUNT   账号
 *  ZENTAO_PASSWORD  明文密码
 */
'use strict';

const crypto = require('crypto');
const {
  Server,
} = require('@modelcontextprotocol/sdk/server/index.js');
const {
  StdioServerTransport,
} = require('@modelcontextprotocol/sdk/server/stdio.js');
const {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} = require('@modelcontextprotocol/sdk/types.js');

// ---------------- 配置 ----------------
const BASE_URL = (process.env.ZENTAO_URL || 'http://192.168.1.212').replace(/\/index\.php\/?$/, '');
const ACCOUNT = process.env.ZENTAO_ACCOUNT || '';
const PASSWORD = process.env.ZENTAO_PASSWORD || '';
const ROUTE_QUERY_KEYS = new Set([
  'id', 'bugID', 'productID', 'projectID', 'executionID', 'storyID', 'taskID',
]);

const md5 = (s) => crypto.createHash('md5').update(s, 'utf8').digest('hex');

// ---------------- 会话管理 ----------------
class ZentaoSession {
  constructor() {
    this.cookies = new Map(); // name -> value
  }

  cookieHeader() {
    return [...this.cookies.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
  }

  absorbSetCookies(res) {
    const raw = [];
    // Node fetch: getSetCookie() (undici >= 0.4) 或 headers.getSetCookie
    if (typeof res.headers.getSetCookie === 'function') {
      raw.push(...res.headers.getSetCookie());
    } else {
      const sc = res.headers.get('set-cookie');
      if (sc) raw.push(...sc.split(/(?<=[,;])\s*(?=[^;=\s]+=)/));
    }
    for (const line of raw) {
      const m = line.match(/^\s*([^=;\s]+)=([^;]*)/);
      if (m) this.cookies.set(m[1], m[2]);
    }
  }

  isLoggedIn() {
    return this.cookies.has('za') && this.cookies.has('zp');
  }

  /** 登录；成功返回 true */
  async login() {
    // 1. 取登录页 + verifyRand
    this.cookies.clear();
    const pageRes = await fetch(`${BASE_URL}/index.php?m=user&f=login`, {
      headers: { 'User-Agent': 'zentao-mcp/1.0' },
    });
    this.absorbSetCookies(pageRes);
    const html = await pageRes.text();
    const rand = (html.match(/verifyRand'?\s*(?:id='verifyRand'\s*)?value='(\d+)'/) || [])[1]
      || (html.match(/verifyRand"?\s*(?:id="verifyRand"\s*)?value="(\d+)"/) || [])[1];
    if (!rand) throw new Error('登录页未找到 verifyRand（服务器响应异常）');

    // 2. 双重 md5 提交
    const form = new URLSearchParams();
    form.set('account', ACCOUNT);
    form.set('password', md5(md5(PASSWORD) + rand));
    form.set('referer', '/');
    form.append('keepLogin[]', 'on');
    const res = await fetch(`${BASE_URL}/index.php?m=user&f=login`, {
      method: 'POST',
      headers: {
        'User-Agent': 'zentao-mcp/1.0',
        'Content-Type': 'application/x-www-form-urlencoded',
        Cookie: this.cookieHeader(),
      },
      body: form.toString(),
      redirect: 'manual',
    });
    this.absorbSetCookies(res);
    await res.text();
    if (!this.isLoggedIn()) {
      throw new Error('禅道登录失败：请检查 ZENTAO_ACCOUNT / ZENTAO_PASSWORD');
    }
    return true;
  }

  /**
   * 调用 m/f&t=json 接口。
   * @param {string} module   例 bug
   * @param {string} method   例 browse
   * @param {object} params   路径/查询参数 例 {productID: 45, status: 'all'}
   * @param {'GET'|'POST'} httpMethod
   */
  async call(module, method, params = {}, httpMethod = 'GET') {
    if (!this.isLoggedIn()) await this.login();

    const doCall = async () => {
      const query = new URLSearchParams({ m: module, f: method, t: 'json' });
      const form = new URLSearchParams();
      for (const [k, v] of Object.entries(params || {})) {
        if (v === undefined || v === null) continue;
        if (httpMethod === 'POST' && ROUTE_QUERY_KEYS.has(k)) {
          query.set(k, String(v));
        } else {
          form.set(k, String(v));
        }
      }
      const formText = form.toString();
      const queryString = httpMethod === 'POST' || formText === ''
        ? query.toString()
        : `${query.toString()}&${formText}`;
      const url = `${BASE_URL}/index.php?${queryString}`;
      const opts = {
        method: httpMethod === 'POST' ? 'POST' : 'GET',
        headers: {
          'User-Agent': 'zentao-mcp/1.0',
          Cookie: this.cookieHeader(),
          'X-Requested-With': 'XMLHttpRequest',
        },
        redirect: 'manual',
      };
      if (httpMethod === 'POST') {
        opts.headers['Content-Type'] = 'application/x-www-form-urlencoded';
        opts.body = formText;
      }
      const res = await fetch(url, opts);
      this.absorbSetCookies(res);
      return res;
    };

    let res = await doCall();
    let text = await res.text();

    // 未登录（keepLogin 失效）→ 重登一次重试
    if (/<html/.test(text) && /f=login/.test(text)) {
      await this.login();
      res = await doCall();
      text = await res.text();
    }

    if (/<html/.test(text)) {
      if (/f=deny/.test(text)) {
        throw new Error(`无权限：当前账号无 ${module}/${method} 权限`);
      }
      if (/f=login/.test(text)) {
        throw new Error('禅道登录态丢失且重登失败：请检查账号密码');
      }
      // 禅道旧版的写接口成功时返回 HTML 跳转脚本，而不是 JSON。
      // 这类响应代表操作已完成，不能被当成接口失败。
      const redirect = text.match(/parent\.location\s*=\s*['"]([^'"]+)['"]/i);
      if (redirect && !/SQLSTATE|ERROR:/i.test(text)) {
        return {
          status: 'success',
          data: { redirect: redirect[1] },
        };
      }
      throw new Error(`禅道返回 HTML 而非 JSON（${module}/${method}），可能页面不存在`);
    }

    let outer;
    try {
      outer = JSON.parse(text);
    } catch {
      throw new Error(`禅道返回非 JSON 内容: ${text.slice(0, 200)}`);
    }
    if (outer.status && outer.status !== 'success') {
      throw new Error(`禅道返回失败: ${JSON.stringify(outer).slice(0, 500)}`);
    }
    // data 是字符串化 JSON → 二次解析
    let data = outer.data;
    if (typeof data === 'string') {
      try { data = JSON.parse(data); } catch { /* 保留原文 */ }
    }
    return { status: outer.status || 'success', data, md5: outer.md5 };
  }
}

const session = new ZentaoSession();

// ---------------- 工具定义 ----------------
const str = (desc, extra = {}) => ({ type: 'string', description: desc, ...extra });
const num = (desc) => ({ type: 'number', description: desc });

function requirePositiveInt(value, fieldName) {
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${fieldName} 必须是正整数`);
  }
  return value;
}

function requireText(value, fieldName) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${fieldName} 不能为空`);
  }
  return value.trim();
}

function optionalText(value, fieldName) {
  if (value === undefined || value === null || value === '') return undefined;
  return requireText(value, fieldName);
}

function optionalPositiveInt(value, fieldName) {
  if (value === undefined || value === null) return undefined;
  return requirePositiveInt(value, fieldName);
}

function addIfPresent(target, key, value) {
  if (value !== undefined) target[key] = value;
}

function bugIdSchema() {
  return num('Bug ID，必须是正整数');
}

function productIdSchema() {
  return num('产品 ID，必须是正整数');
}

const TOOLS = [
  {
    name: 'zentao_call',
    description:
      '通用禅道接口调用（pro8.2 任意 m=模块&f=方法&t=json）。当专用工具不覆盖时使用。'
      + '常用模块: product/project/bug/task/story/user/dept/todo/my/execution 等。',
    inputSchema: {
      type: 'object',
      properties: {
        module: str('模块名，如 bug、task、story、product、project、user'),
        method: str('方法名，如 browse、view、create、resolve、close、assignTo'),
        params: {
          type: 'object',
          description: '接口参数（如 productID/bugID/status），值为标量',
          additionalProperties: true,
        },
        httpMethod: str('HTTP 方法，默认 GET；写操作（create/resolve/close/finish 等）用 POST', {
          enum: ['GET', 'POST'],
        }),
      },
      required: ['module', 'method'],
    },
  },
  {
    name: 'zentao_my_dashboard',
    description: '我的地盘：待处理任务/Bug/统计概览',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_my_tasks',
    description: '指派给我的任务列表',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_my_bugs',
    description: '指派给我的 Bug 列表',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_my_assigned_bugs',
    description: '查询当前账号指派到名下的 Bug。返回 Bug 列表、分页信息和可用用户映射。',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_create_bug',
    description: '创建 Bug。需要产品 ID、标题和重现步骤；写入后返回禅道响应。',
    inputSchema: {
      type: 'object',
      properties: {
        productID: productIdSchema(),
        title: str('Bug 标题'),
        steps: str('重现步骤、实际结果和期望结果，建议使用文本或 HTML'),
        severity: num('严重程度，默认 3'),
        priority: num('优先级，默认 3'),
        type: str('Bug 类型，默认 codeerror'),
        openedBuild: str('发现版本，默认 trunk'),
        assignedTo: str('处理人禅道账号，可选'),
        branch: num('产品分支 ID，可选'),
        moduleID: num('产品模块 ID，可选'),
        projectID: num('项目 ID，可选'),
        executionID: num('执行/迭代 ID，可选'),
        storyID: num('需求 ID，可选'),
        taskID: num('任务 ID，可选'),
        os: str('操作系统，可选'),
        browser: str('浏览器，可选'),
        keywords: str('关键词，可选'),
        mailto: str('抄送账号，多个账号按禅道格式传入，可选'),
      },
      required: ['productID', 'title', 'steps'],
    },
  },
  {
    name: 'zentao_resolve_bug',
    description: '将 Bug 标记为已解决。默认解决方案为 fixed，可填写解决版本和备注。',
    inputSchema: {
      type: 'object',
      properties: {
        bugID: bugIdSchema(),
        resolution: str('解决方案，例如 fixed、duplicate、wontfix、bydesign、tostory'),
        resolvedBuild: str('解决版本，可选'),
        comment: str('解决备注，可选'),
      },
      required: ['bugID'],
    },
  },
  {
    name: 'zentao_assign_bug',
    description: '将 Bug 指派给指定禅道账号。assignedTo 必须是账号，不是显示姓名。',
    inputSchema: {
      type: 'object',
      properties: {
        bugID: bugIdSchema(),
        assignedTo: str('接收人禅道账号，例如 tester01'),
        comment: str('指派备注，可选'),
      },
      required: ['bugID', 'assignedTo'],
    },
  },
  {
    name: 'zentao_reopen_bug',
    description: '重新激活已解决或已关闭的 Bug。禅道旧版接口使用 bug/activate。',
    inputSchema: {
      type: 'object',
      properties: {
        bugID: bugIdSchema(),
        comment: str('重新打开备注，可选'),
      },
      required: ['bugID'],
    },
  },
  {
    name: 'zentao_verify_bug_update',
    description: '重新读取 Bug 详情，并核对期望状态、处理人、解决方案和解决版本。',
    inputSchema: {
      type: 'object',
      properties: {
        bugID: bugIdSchema(),
        expectedStatus: str('期望状态，例如 active、resolved、closed，可选'),
        expectedAssignedTo: str('期望处理人账号，可选'),
        expectedResolution: str('期望解决方案，可选'),
        expectedResolvedBuild: str('期望解决版本，可选'),
      },
      required: ['bugID'],
    },
  },
  {
    name: 'zentao_my_todos',
    description: '我的待办事项',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_list_products',
    description: '全部产品列表',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_product_detail',
    description: '产品详情',
    inputSchema: {
      type: 'object',
      properties: { productID: num('产品 ID') },
      required: ['productID'],
    },
  },
  {
    name: 'zentao_list_stories',
    description: '产品需求列表',
    inputSchema: {
      type: 'object',
      properties: {
        productID: num('产品 ID'),
        status: str('筛选: all/active/closed/changed（默认 all）'),
      },
      required: ['productID'],
    },
  },
  {
    name: 'zentao_story_detail',
    description: '需求详情',
    inputSchema: {
      type: 'object',
      properties: { storyID: num('需求 ID') },
      required: ['storyID'],
    },
  },
  {
    name: 'zentao_list_projects',
    description: '全部项目列表',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'zentao_project_detail',
    description: '项目详情',
    inputSchema: {
      type: 'object',
      properties: { projectID: num('项目 ID') },
      required: ['projectID'],
    },
  },
  {
    name: 'zentao_list_tasks',
    description: '项目任务列表',
    inputSchema: {
      type: 'object',
      properties: {
        projectID: num('项目 ID'),
        type: str('筛选: all/unclosed/waiting/doing/done/closed（默认 all）'),
      },
      required: ['projectID'],
    },
  },
  {
    name: 'zentao_task_detail',
    description: '任务详情',
    inputSchema: {
      type: 'object',
      properties: { taskID: num('任务 ID') },
      required: ['taskID'],
    },
  },
  {
    name: 'zentao_list_bugs',
    description: '产品 Bug 列表',
    inputSchema: {
      type: 'object',
      properties: {
        productID: num('产品 ID'),
        type: str('筛选: all/unclosed/unresolved/assignedtome/closed 等（默认 all）'),
      },
      required: ['productID'],
    },
  },
  {
    name: 'zentao_bug_detail',
    description: 'Bug 详情（含重现步骤）',
    inputSchema: {
      type: 'object',
      properties: { bugID: num('Bug ID') },
      required: ['bugID'],
    },
  },
];

// 专用工具 → (session, args) 映射
const HANDLERS = {
  zentao_call: (a) => session.call(a.module, a.method, a.params, a.httpMethod || 'GET'),
  zentao_my_dashboard: () => session.call('my', 'index'),
  zentao_my_tasks: () => session.call('my', 'task'),
  zentao_my_bugs: () => session.call('my', 'bug'),
  zentao_my_assigned_bugs: () => session.call('my', 'bug'),
  zentao_create_bug: (a) => {
    const params = {
      product: requirePositiveInt(a.productID, 'productID'),
      title: requireText(a.title, 'title'),
      steps: requireText(a.steps, 'steps'),
      severity: a.severity === undefined ? 3 : requirePositiveInt(a.severity, 'severity'),
      pri: a.priority === undefined ? 3 : requirePositiveInt(a.priority, 'priority'),
      type: optionalText(a.type, 'type') || 'codeerror',
      openedBuild: optionalText(a.openedBuild, 'openedBuild') || 'trunk',
    };
    addIfPresent(params, 'assignedTo', optionalText(a.assignedTo, 'assignedTo'));
    addIfPresent(params, 'branch', optionalPositiveInt(a.branch, 'branch'));
    addIfPresent(params, 'module', optionalPositiveInt(a.moduleID, 'moduleID'));
    addIfPresent(params, 'project', optionalPositiveInt(a.projectID, 'projectID'));
    addIfPresent(params, 'execution', optionalPositiveInt(a.executionID, 'executionID'));
    addIfPresent(params, 'story', optionalPositiveInt(a.storyID, 'storyID'));
    addIfPresent(params, 'task', optionalPositiveInt(a.taskID, 'taskID'));
    addIfPresent(params, 'os', optionalText(a.os, 'os'));
    addIfPresent(params, 'browser', optionalText(a.browser, 'browser'));
    addIfPresent(params, 'keywords', optionalText(a.keywords, 'keywords'));
    addIfPresent(params, 'mailto', optionalText(a.mailto, 'mailto'));
    return session.call('bug', 'create', params, 'POST');
  },
  zentao_resolve_bug: (a) => {
    const params = {
      bugID: requirePositiveInt(a.bugID, 'bugID'),
      resolution: optionalText(a.resolution, 'resolution') || 'fixed',
    };
    addIfPresent(params, 'resolvedBuild', optionalText(a.resolvedBuild, 'resolvedBuild'));
    addIfPresent(params, 'comment', optionalText(a.comment, 'comment'));
    return session.call('bug', 'resolve', params, 'POST');
  },
  zentao_assign_bug: (a) => {
    const params = {
      bugID: requirePositiveInt(a.bugID, 'bugID'),
      assignedTo: requireText(a.assignedTo, 'assignedTo'),
    };
    addIfPresent(params, 'comment', optionalText(a.comment, 'comment'));
    return session.call('bug', 'assignTo', params, 'POST');
  },
  zentao_reopen_bug: (a) => {
    const params = { bugID: requirePositiveInt(a.bugID, 'bugID') };
    addIfPresent(params, 'comment', optionalText(a.comment, 'comment'));
    return session.call('bug', 'activate', params, 'POST');
  },
  zentao_verify_bug_update: async (a) => {
    const bugID = requirePositiveInt(a.bugID, 'bugID');
    const result = await session.call('bug', 'view', { bugID });
    const bug = result.data?.bug && typeof result.data.bug === 'object' ? result.data.bug : result.data;
    if (!bug || typeof bug !== 'object') {
      throw new Error(`Bug #${bugID} 详情格式无法识别`);
    }
    const expected = {};
    addIfPresent(expected, 'status', optionalText(a.expectedStatus, 'expectedStatus'));
    addIfPresent(expected, 'assignedTo', optionalText(a.expectedAssignedTo, 'expectedAssignedTo'));
    addIfPresent(expected, 'resolution', optionalText(a.expectedResolution, 'expectedResolution'));
    addIfPresent(expected, 'resolvedBuild', optionalText(a.expectedResolvedBuild, 'expectedResolvedBuild'));
    if (Object.keys(expected).length === 0) {
      throw new Error('至少提供一个期望字段：expectedStatus、expectedAssignedTo、expectedResolution 或 expectedResolvedBuild');
    }
    const mismatches = Object.entries(expected)
      .filter(([field, value]) => String(bug[field] ?? '') !== String(value))
      .map(([field, expectedValue]) => ({
        field,
        expected: expectedValue,
        actual: bug[field] ?? null,
      }));
    return {
      verified: mismatches.length === 0,
      bug,
      expected,
      mismatches,
    };
  },
  zentao_my_todos: () => session.call('my', 'todo'),
  zentao_list_products: () => session.call('product', 'all'),
  zentao_product_detail: (a) => session.call('product', 'view', { productID: a.productID }),
  zentao_list_stories: (a) => session.call('story', 'browse', { productID: a.productID, type: a.status || 'all' }),
  zentao_story_detail: (a) => session.call('story', 'view', { storyID: a.storyID }),
  zentao_list_projects: () => session.call('project', 'all'),
  zentao_project_detail: (a) => session.call('project', 'view', { projectID: a.projectID }),
  zentao_list_tasks: (a) => session.call('project', 'task', { projectID: a.projectID, type: a.type || 'all', param: 0 }),
  zentao_task_detail: (a) => session.call('task', 'view', { taskID: a.taskID }),
  zentao_list_bugs: (a) => session.call('bug', 'browse', { productID: a.productID, type: a.type || 'all' }),
  zentao_bug_detail: (a) => session.call('bug', 'view', { bugID: a.bugID }),
};

// ---------------- MCP server ----------------
const MAX_TEXT = 120000;

const server = new Server(
  { name: 'zentao', version: '1.0.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;
  const handler = HANDLERS[name];
  if (!handler) {
    return {
      content: [{ type: 'text', text: `未知工具: ${name}` }],
      isError: true,
    };
  }
  try {
    const result = await handler(args);
    let text = JSON.stringify(result.data !== undefined ? result.data : result, null, 2);
    if (text.length > MAX_TEXT) {
      text = `${text.slice(0, MAX_TEXT)}\n...[结果已截断，共 ${text.length} 字符。可用更精确的参数缩小范围]`;
    }
    return { content: [{ type: 'text', text }] };
  } catch (err) {
    return {
      content: [{ type: 'text', text: `错误: ${err.message}` }],
      isError: true,
    };
  }
});

async function main() {
  if (!ACCOUNT || !PASSWORD) {
    process.stderr.write('[zentao-mcp] 缺少 ZENTAO_ACCOUNT / ZENTAO_PASSWORD 环境变量\n');
  }
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`[zentao-mcp] ready (target ${BASE_URL})\n`);
}

main().catch((e) => {
  process.stderr.write(`[zentao-mcp] fatal: ${e.message}\n`);
  process.exit(1);
});
