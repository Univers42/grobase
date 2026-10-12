# stack-health-edges.awk — the edge parser behind `stack-health.sh parse-edges`.
#
# Input lines (one container attribute each, the container name carrying docker's leading /):
#   S /name service status      A /name alias        P /name port/proto
#   D /name depends_on-label    E /name env-or-cmd   K kong-upstream-url
# Output: "client host port[,port]" for every edge whose host is another running container.
#
# Ponytail: `<host>:<digits>` is matched textually, so an address without an explicit port
# is not an explicit edge; see stack-health.sh for what that misses and over-reports.

# scan prints each host:port in text that names another running container than client.
function scan(client, text,    tok, part) {
  while (match(text, /[A-Za-z0-9][A-Za-z0-9_.-]*:[0-9]+/)) {
    tok = substr(text, RSTART, RLENGTH); text = substr(text, RSTART + RLENGTH)
    split(tok, part, ":")
    if ((part[1] in owner) && owner[part[1]] != client && up[owner[part[1]]]) {
      explicit[client, owner[part[1]]] = 1; print client, part[1], part[2]
    }
  }
}
# implied prints, for each dependency in list with no explicit edge, its exposed tcp ports.
function implied(client, list,    count, i, items, target) {
  count = split(list, items, ",")
  for (i = 1; i <= count; i++) {
    sub(/:.*/, "", items[i]); target = owner[items[i]]
    if (up[target] && ports[target] != "" && !((client, target) in explicit)) print client, items[i], ports[target]
  }
}
$1 == "S" { name = substr($2, 2); owner[name] = name; owner[$3] = name; if ($4 == "running") up[name] = 1; next }
$1 == "A" { owner[$3] = substr($2, 2); next }
$1 == "P" && $3 ~ /\/tcp$/ { sub(/\/tcp$/, "", $3); name = substr($2, 2); ports[name] = ports[name] (ports[name] == "" ? "" : ",") $3; next }
$1 == "D" { needs[substr($2, 2)] = $3; next }
$1 == "E" || $1 == "K" { line[++count] = $0 }
END {
  for (i = 1; i <= count; i++) {
    split(line[i], field, " ")
    client = (field[1] == "K") ? owner["kong"] : substr(field[2], 2)
    if (up[client]) scan(client, line[i])
  }
  for (client in needs) if (up[client]) implied(client, needs[client])
}
