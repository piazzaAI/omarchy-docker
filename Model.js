.pragma library

// The themes only carry foreground / accent / urgent / muted, so stack state is
// expressed as a role the panel resolves against the live palette rather than a
// literal green or amber that would fight every light theme.
var ROLE_ACTIVE = "active"
var ROLE_MIXED = "mixed"
var ROLE_OFF = "off"
var ROLE_UNKNOWN = "unknown"

function stateRole(state) {
  if (state === "running") return ROLE_ACTIVE
  if (state === "partial") return ROLE_MIXED
  if (state === "stopped") return ROLE_OFF
  return ROLE_UNKNOWN
}

// What the row says to the right of the name. The daemon's own status string is
// the most informative thing available once a stack is not simply all-up.
function stateLabel(stack) {
  if (!stack) return ""
  if (stack.state === "running") return stack.total + (stack.total === 1 ? " container" : " containers")
  if (stack.state === "idle") return "never started"
  if (stack.status) return stack.status
  if (stack.state === "partial") return stack.running + "/" + stack.total + " up"
  return "stopped"
}

function isUp(stack) {
  return !!stack && (stack.state === "running" || stack.state === "partial")
}

// Ordered as they appear in the row and in the footer hints. `l` is not
// available: the panel key catcher claims h/j/k/l for navigation.
function actions() {
  return [
    { action: "up",      label: "Up",      key: "u", needsUp: false },
    { action: "down",    label: "Down",    key: "d", needsUp: true },
    { action: "restart", label: "Restart", key: "r", needsUp: true },
    { action: "build",   label: "Build",   key: "b", needsUp: false },
    { action: "rebuild", label: "Rebuild", key: "f", needsUp: false },
    { action: "logs",    label: "Logs",    key: "o", needsUp: true }
  ]
}

function actionForKey(key) {
  var all = actions()
  for (var i = 0; i < all.length; i++)
    if (all[i].key === key) return all[i].action
  return ""
}

// The row never changes shape as state moves; only the actions that cannot mean
// anything on a fully stopped stack go dim. `up` and the two build actions stay
// live on a running stack -- re-running them after a compose edit is the point.
function actionEnabled(entry, stack) {
  if (!stack) return false
  return entry.needsUp ? isUp(stack) : true
}

function visibleStacks(stacks, hideIdle) {
  if (!stacks) return []
  if (!hideIdle) return stacks
  var rows = []
  for (var i = 0; i < stacks.length; i++)
    if (stacks[i].state !== "idle") rows.push(stacks[i])
  return rows
}

function runningCount(stacks) {
  var n = 0
  for (var i = 0; i < (stacks ? stacks.length : 0); i++)
    if (isUp(stacks[i])) n++
  return n
}

function summaryRole(stacks) {
  if (!stacks || stacks.length === 0) return ROLE_UNKNOWN
  var up = runningCount(stacks)
  if (up === 0) return ROLE_OFF
  if (up === stacks.length) return ROLE_ACTIVE
  return ROLE_MIXED
}
