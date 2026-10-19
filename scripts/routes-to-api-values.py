#!/usr/bin/env python3
"""Turn OpenShift Routes and Kubernetes Ingresses into API files for the GitOps repo.

    oc get routes,ingresses,services -A -o json > cluster.json
    scripts/routes-to-api-values.py cluster.json \
        --gateway-hostname '*.api.example.internal' \
        --rehost apps.ocp.example.internal=api.example.internal

Writes apis/<namespace>/<release>.yaml (one per Route, one per Ingress host), which Argo CD
deploys with charts/api once committed, and migration-report.md with the listeners to add,
the warnings, test commands and the old objects to delete after cutover.
Nothing is applied to the cluster.

Every generated API starts with auth.mode=public, so it keeps working the way the
Route did; switch each to protected once its callers have credentials.
"""
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

SKIP_NS_PREFIXES = ("openshift", "kube-")
SKIP_NS = {"api-gateway", "istio-system", "istio-cni", "kuadrant-system"}
DURATION = re.compile(r"^([0-9]{1,5}(h|m|s|ms)){1,4}$")


# --- minimal YAML writer (strings are JSON-quoted, which is valid YAML) ---------------

def to_yaml(value, indent=0):
    pad = " " * indent
    if isinstance(value, dict):
        if not value:
            return "{}"
        lines = []
        for k, v in value.items():
            if isinstance(v, (dict, list)) and v:
                lines.append(f"{pad}{k}:\n{to_yaml(v, indent + 2)}")
            else:
                lines.append(f"{pad}{k}: {to_yaml(v)}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "[]"
        lines = []
        for item in value:
            if isinstance(item, (dict, list)) and item:
                body = to_yaml(item, indent + 2)
                lines.append(f"{pad}- {body[indent + 2:]}")
            else:
                lines.append(f"{pad}- {to_yaml(item)}")
        return "\n".join(lines)
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(value)


# --- helpers -----------------------------------------------------------------------------

def service_port(svc, wanted, warnings):
    """Resolve a Route targetPort or Ingress port name/number to the Service's port number."""
    if svc is None:
        warnings.append("backend Service not found; set the port by hand")
        return 80
    ports = svc["spec"].get("ports", [])
    if wanted is None:
        if len(ports) != 1:
            warnings.append(f"no port given and Service has {len(ports)} ports; used the first")
        return ports[0]["port"] if ports else 80
    for p in ports:
        tp = p.get("targetPort", p["port"])
        if wanted in (p.get("name"), p["port"], tp) or str(wanted) in (str(tp), str(p["port"])):
            return p["port"]
    warnings.append(f"port {wanted!r} not found on Service {svc['metadata']['name']}; set it by hand")
    return 80


def rehost(host, mappings):
    for old, new in mappings:
        if host == old or host.endswith("." + old):
            return host[: len(host) - len(old)] + new
    return host


def coverage_warning(host, gateway_hostname):
    """Gateway wildcards match any depth, but a wildcard certificate covers only one label."""
    if not gateway_hostname.startswith("*."):
        return None if host == gateway_hostname else f"{host} is not covered by listener {gateway_hostname}"
    suffix = gateway_hostname[1:]
    if not host.endswith(suffix):
        return f"{host} is not under {gateway_hostname}; needs its own gateway listener"
    if "." in host[: -len(suffix)]:
        return f"{host} is more than one label below {gateway_hostname[2:]}; the wildcard certificate will not cover it"
    return None


# --- converters --------------------------------------------------------------------------

def convert_route(route, services, warnings):
    meta, spec = route["metadata"], route["spec"]
    ns = meta["namespace"]
    tls = spec.get("tls") or {}
    termination = tls.get("termination")

    if termination == "passthrough":
        return None, "passthrough TLS needs a TLSRoute and a passthrough listener; not converted"
    if spec.get("wildcardPolicy") == "Subdomain":
        warnings.append("wildcardPolicy Subdomain: list each hostname explicitly")
    if termination == "reencrypt":
        warnings.append("reencrypt: the backend serves TLS. In the mesh, let it serve plain HTTP (sidecars add mTLS) or add a BackendTLSPolicy")
    if termination == "edge" and tls.get("certificate"):
        warnings.append("Route had its own certificate; the gateway listener certificate is used instead")
    if tls.get("insecureEdgeTerminationPolicy") == "Allow":
        warnings.append("Route allowed plain HTTP; the gateway redirects HTTP to HTTPS")

    backends = []
    weighted = bool(spec.get("alternateBackends"))
    wanted = (spec.get("port") or {}).get("targetPort")
    for to in [spec["to"], *spec.get("alternateBackends", [])]:
        ref = {"name": to["name"], "port": service_port(services.get((ns, to["name"])), wanted, warnings)}
        if weighted:
            ref["weight"] = to.get("weight", 100)
        backends.append(ref)

    rule = {"matches": [{"path": {"type": "PathPrefix", "value": spec.get("path") or "/"}}],
            "backendRefs": backends}

    for key, val in (meta.get("annotations") or {}).items():
        if key == "haproxy.router.openshift.io/timeout" and DURATION.match(val):
            rule["timeouts"] = {"request": val}
        elif key.startswith("haproxy.router.openshift.io/") or key.startswith("router.openshift.io/"):
            warnings.append(f"annotation {key}={val} has no automatic equivalent; review it")

    host = spec.get("host")
    if not host:
        return None, "Route has no host; not converted"
    return [(host, [rule], [])], None


def convert_ingress(ing, services, warnings):
    meta, spec = ing["metadata"], ing["spec"]
    ns = meta["namespace"]
    if spec.get("defaultBackend"):
        warnings.append("defaultBackend is not converted")
    if spec.get("tls"):
        warnings.append("Ingress had its own TLS secret; the gateway listener certificate is used instead")
    for key, val in (meta.get("annotations") or {}).items():
        if "openshift.io" in key or "nginx" in key:
            warnings.append(f"annotation {key}={val} has no automatic equivalent; review it")

    by_host = []
    for rule in spec.get("rules", []):
        host = rule.get("host")
        if not host:
            warnings.append("Ingress rule without host skipped")
            continue
        rules, host_warnings = [], []
        for p in (rule.get("http") or {}).get("paths", []):
            svc_backend = p["backend"].get("service")
            if not svc_backend:
                host_warnings.append("resource backend skipped")
                continue
            ptype = p.get("pathType", "Prefix")
            if ptype == "ImplementationSpecific":
                host_warnings.append(f"path {p.get('path', '/')}: ImplementationSpecific converted to PathPrefix")
            port = svc_backend.get("port", {})
            wanted = port.get("number", port.get("name"))
            svc = services.get((ns, svc_backend["name"]))
            rules.append({
                "matches": [{"path": {"type": "Exact" if ptype == "Exact" else "PathPrefix",
                                      "value": p.get("path") or "/"}}],
                "backendRefs": [{"name": svc_backend["name"], "port": service_port(svc, wanted, host_warnings)}],
            })
        if rules:
            by_host.append((host, rules, host_warnings))
    if not by_host:
        return None, "no convertible rules"
    return by_host, None


# --- main --------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="output of: oc get routes,ingresses,services -A -o json")
    ap.add_argument("--out", default="apis", help="the repo's apis/ directory")
    ap.add_argument("--report", default="migration-report.md")
    ap.add_argument("--gateway-hostname", default="*.api.example.internal",
                    help="hostname of the gateway's main HTTPS listener")
    ap.add_argument("--rehost", action="append", default=[], metavar="OLD=NEW",
                    help="rewrite a hostname suffix, e.g. apps.ocp.example.internal=api.example.internal")
    ap.add_argument("--include-system", action="store_true",
                    help="also convert openshift-*/kube-* namespaces (normally left on the router)")
    args = ap.parse_args()

    mappings = [tuple(m.split("=", 1)) for m in args.rehost]
    items = json.loads(Path(args.input).read_text())["items"]
    services = {(i["metadata"]["namespace"], i["metadata"]["name"]): i for i in items if i["kind"] == "Service"}

    out = Path(args.out)
    report = defaultdict(list)
    namespaces, extra_listeners = set(), set()

    for obj in items:
        kind, meta = obj["kind"], obj["metadata"]
        if kind not in ("Route", "Ingress"):
            continue
        ns, name = meta["namespace"], meta["name"]
        if not args.include_system and (ns in SKIP_NS or ns.startswith(SKIP_NS_PREFIXES)):
            continue
        # OpenShift creates a Route for every Ingress; convert the Ingress, not its Routes.
        if kind == "Route" and any(o.get("kind") == "Ingress" for o in meta.get("ownerReferences", [])):
            continue

        warnings = []
        convert = convert_route if kind == "Route" else convert_ingress
        result, skip_reason = convert(obj, services, warnings)
        if result is None:
            report["skipped"].append(f"{kind} {ns}/{name}: {skip_reason}")
            continue

        for idx, (old_host, rules, own_warnings) in enumerate(result):
            host = rehost(old_host, mappings)
            release = name if len(result) == 1 else f"{name}-{idx + 1}"
            host_warnings = warnings + own_warnings
            if host != old_host:
                host_warnings.append(f"hostname changed: {old_host} -> {host}")
            values = {"nameOverride": release}
            cov = coverage_warning(host, args.gateway_hostname)
            if cov:
                # The extra listener is named after its hostname (a valid listener name).
                host_warnings.append(cov + f" (listener name: {host})")
                extra_listeners.add(host)
                values["gateway"] = {"sectionName": host}
            values.update({
                "hostnames": [host],
                "rules": rules,
                "auth": {"mode": "public"},
            })
            path = out / ns / f"{release}.yaml"
            if path.exists():
                report["skipped"].append(f"{kind} {ns}/{name}: {path} already exists, left unchanged")
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            header = [f"# Generated from {kind} {ns}/{name} by routes-to-api-values.py",
                      "# auth.mode=public keeps today's behaviour. Switch to protected when callers have credentials.",
                      "# The chart's default route-wide rate limit (rateLimit.total) applies."]
            header += [f"# WARNING: {w}" for w in host_warnings]
            path.write_text("\n".join(header) + "\n" + to_yaml(values) + "\n")

            namespaces.add(ns)
            report["install"].append(str(path))
            report["test"].append(f"curl -sS --resolve {host}:443:$GW_IP https://{host}/ -o /dev/null -w '%{{http_code}} {host}\\n'")
            delete = f"oc delete {kind.lower()} {name} -n {ns}"
            if delete not in report["delete"]:
                report["delete"].append(delete)
            report["warnings"] += [f"{ns}/{release}: {w}" for w in host_warnings]

    lines = ["# Route/Ingress migration plan", ""]
    if extra_listeners:
        lines += ["## 1. Add gateway listeners",
                  "",
                  "These hostnames need their own listener. Add them to `gateway.extraListeners` in",
                  "`site/platform-values.yaml` (the generated files already attach to them by name):", "", "```yaml"]
        for h in sorted(extra_listeners):
            lines += [f"- name: {h}", f"  hostname: {h}"]
        lines += ["```", ""]
    lines += ["## 2. Review and commit the generated API files", "",
              "Read the WARNING lines at the top of each file. After Argo CD syncs, the old Routes keep serving traffic.", ""]
    lines += [f"- `{f}`" for f in report["install"]] + [""]
    lines += ["## 3. Restart workloads so they get the Istio sidecar", "", "```bash"]
    lines += [f"oc rollout restart deployment,statefulset -n {ns}" for ns in sorted(namespaces)] + ["```", ""]
    lines += ["## 4. Test through the gateway before changing DNS", "",
              "```bash", "GW_IP=$(oc get gateway api-gateway -n api-gateway -o jsonpath='{.status.addresses[0].value}')"]
    lines += report["test"] + ["```", ""]
    lines += ["## 5. Switch DNS to the gateway, then delete the old objects", "",
              "If the Routes/Ingresses are themselves managed in Git, remove them there instead.", "", "```bash"]
    lines += report["delete"] + ["```", ""]
    if report["warnings"]:
        lines += ["## Warnings", ""] + [f"- {w}" for w in report["warnings"]] + [""]
    if report["skipped"]:
        lines += ["## Not converted", ""] + [f"- {s}" for s in report["skipped"]] + [""]
    Path(args.report).write_text("\n".join(lines))

    print(f"{len(report['install'])} API files written to {out}/, {len(report['skipped'])} skipped, "
          f"{len(report['warnings'])} warnings -> {args.report}")


if __name__ == "__main__":
    sys.exit(main())
