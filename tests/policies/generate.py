#!/usr/bin/env python3
"""Generate the kyverno test cases under tests/policies/.

Every case starts from one compliant Pod and changes exactly one thing, so a
failing case shows that the policy catches that one violation and nothing
else trips it. Each policy gets a directory with resources.yaml and
kyverno-test.yaml; `make policy-test` runs them all.

Re-run after changing the cases: python3 tests/policies/generate.py
"""
import copy
import pathlib

import yaml

HERE = pathlib.Path(__file__).parent
SIGNED = ("127.0.0.1:30500/library/alpine:3.22@sha256:"
          "49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f")

BASE = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        "name": "compliant",
        "namespace": "apps",
        "labels": {"app.kubernetes.io/name": "web"},
    },
    "spec": {
        "automountServiceAccountToken": False,
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 65532,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "containers": [{
            "name": "app",
            "image": SIGNED,
            "securityContext": {
                "allowPrivilegeEscalation": False,
                "capabilities": {"drop": ["ALL"]},
            },
            "resources": {
                "requests": {"cpu": "10m", "memory": "16Mi"},
                "limits": {"memory": "32Mi"},
            },
        }],
        "volumes": [{"name": "tmp", "emptyDir": {}}],
    },
}


def pod(name, change=None, namespace="apps"):
    p = copy.deepcopy(BASE)
    p["metadata"]["name"] = name
    p["metadata"]["namespace"] = namespace
    if change:
        change(p["spec"], p["metadata"])
    return p


def deployment(name, change=None, namespace="apps"):
    p = pod(name, change, namespace)
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app.kubernetes.io/name": "web"}},
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": {"app.kubernetes.io/name": "web"}},
            "template": {"metadata": p["metadata"] | {"name": None},
                         "spec": p["spec"]},
        },
    }


def c0(spec):
    return spec["containers"][0]


def set_(path, value, target="container"):
    """Return a change function that sets a nested key."""
    def change(spec, meta):
        obj = {"container": lambda: c0(spec), "pod": lambda: spec,
               "meta": lambda: meta}[target]()
        *parents, last = path
        for k in parents:
            obj = obj.setdefault(k, {})
        obj[last] = value
    return change


def delete(path, target="container"):
    def change(spec, meta):
        obj = {"container": lambda: c0(spec), "pod": lambda: spec,
               "meta": lambda: meta}[target]()
        *parents, last = path
        for k in parents:
            obj = obj[k]
        del obj[last]
    return change


def add_volume(vol):
    def change(spec, meta):
        spec["volumes"].append(vol)
    return change


# policy -> (passing, failing[, skipped]); each case is
# (name, kind, change[, namespace]). Skipped: a PolicyException applies.
EXCEPTIONS = {
    "restrict-image-registries": ["exception-platform-bootstrap-images.yaml", "exception-kube-bench.yaml"],
    "disallow-host-path": ["exception-local-path-helper.yaml", "exception-kube-bench.yaml",
                           "exception-velero-node-agent.yaml"],
    "pod-security-restricted": ["exception-local-path-helper.yaml", "exception-kube-bench.yaml",
                                "exception-velero-node-agent.yaml"],
    "disallow-privileged-containers": ["exception-kube-bench.yaml", "exception-velero-node-agent.yaml"],
}
KUBE_BENCH = ("docker.io/aquasec/kube-bench@sha256:"
              "75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679")


def kube_bench(*changes):
    """The kube-bench label plus other changes."""
    def change(spec, meta):
        meta["labels"]["app.kubernetes.io/name"] = "kube-bench"
        for c in changes:
            c(spec, meta)
    return change


def node_agent(*changes):
    """Velero's node-agent pod label plus other changes."""
    def change(spec, meta):
        meta["labels"]["name"] = "node-agent"
        for c in changes:
            c(spec, meta)
    return change


def velero_hosting_pod(*changes):
    """A Velero 1.18 per-volume hosting pod's label plus other changes."""
    def change(spec, meta):
        meta["labels"]["velero.io/pod-volume-backup"] = "sample-app-drill-abc12"
        for c in changes:
            c(spec, meta)
    return change
HOST_PODS = {"name": "host-pods", "hostPath": {"path": "/var/lib/kubelet/pods"}}
VELERO = "docker.io/velero/velero:v1.18.4"
HOST_PATH = {"name": "data", "hostPath": {"path": "/opt/local-path-provisioner"}}
ARGOCD = "quay.io/argoproj/argocd:v3.6.1"

CASES = {
    "disallow-privileged-containers": (
        [("compliant", pod, None)],
        [("privileged", pod, set_(["securityContext", "privileged"], True)),
         ("privileged-deploy", deployment, set_(["securityContext", "privileged"], True)),
         # kube-bench exception: needs both the namespace and the label
         ("privileged-kube-bench-ns-other-label", pod, set_(["securityContext", "privileged"], True), "kube-bench"),
         ("privileged-kube-bench-label-other-ns", pod, kube_bench(set_(["securityContext", "privileged"], True))),
         # privileged only for Velero's hosting pods, not the node agent
         ("privileged-velero-node-agent", pod, node_agent(set_(["securityContext", "privileged"], True)), "velero"),
         ("privileged-hosting-pod-other-ns", pod, velero_hosting_pod(set_(["securityContext", "privileged"], True)))],
        [("kube-bench-privileged", pod, kube_bench(set_(["securityContext", "privileged"], True)), "kube-bench"),
         ("velero-hosting-pod-privileged", pod, velero_hosting_pod(set_(["securityContext", "privileged"], True)), "velero")],
    ),
    "disallow-host-path": (
        [("compliant", pod, None)],
        [("host-path", pod, add_volume({"name": "host", "hostPath": {"path": "/etc"}})),
         ("host-path-deploy", deployment, add_volume({"name": "host", "hostPath": {"path": "/etc"}})),
         # the helper exception is scoped to its namespace and name prefix
         ("helper-pod-create-pvc-other-ns", pod, add_volume(HOST_PATH)),
         ("not-a-helper", pod, add_volume(HOST_PATH), "local-path-storage"),
         # the node-agent exception needs both the namespace and the label
         ("node-agent-label-other-ns", pod, node_agent(add_volume(HOST_PODS))),
         ("hosting-pod-label-other-ns", pod, velero_hosting_pod(add_volume(HOST_PODS))),
         ("not-node-agent-in-velero", pod, add_volume(HOST_PODS), "velero")],
        [("helper-pod-create-pvc-1", pod, add_volume(HOST_PATH), "local-path-storage"),
         ("kube-bench-host-path", pod, kube_bench(add_volume({"name": "etc", "hostPath": {"path": "/etc/rancher"}})), "kube-bench"),
         ("velero-node-agent-host-pods", pod, node_agent(add_volume(HOST_PODS)), "velero"),
         ("velero-hosting-pod-host-pods", pod, velero_hosting_pod(add_volume(HOST_PODS)), "velero")],
    ),
    "pod-security-restricted": (
        [("compliant", pod, None),
         ("compliant-deploy", deployment, None),
         ("net-bind-service", pod, set_(["securityContext", "capabilities", "add"], ["NET_BIND_SERVICE"])),
         ("container-level-seccomp", pod, lambda s, m: (
             s["securityContext"].pop("seccompProfile"),
             c0(s)["securityContext"].update({"seccompProfile": {"type": "RuntimeDefault"}})))],
        [("host-network", pod, set_(["hostNetwork"], True, "pod")),
         ("host-pid", pod, set_(["hostPID"], True, "pod")),
         ("host-port", pod, set_(["ports"], [{"containerPort": 80, "hostPort": 80}])),
         ("cap-add-sys-admin", pod, set_(["securityContext", "capabilities", "add"], ["SYS_ADMIN"])),
         ("no-cap-drop", pod, delete(["securityContext", "capabilities"])),
         ("privilege-escalation", pod, set_(["securityContext", "allowPrivilegeEscalation"], True)),
         ("escalation-unset", pod, delete(["securityContext", "allowPrivilegeEscalation"])),
         ("run-as-root", pod, set_(["securityContext", "runAsNonRoot"], False, "pod")),
         ("uid-zero", pod, set_(["securityContext", "runAsUser"], 0)),
         ("no-seccomp", pod, delete(["securityContext", "seccompProfile"], "pod")),
         ("seccomp-unconfined", pod, set_(["securityContext", "seccompProfile", "type"], "Unconfined")),
         ("apparmor-unconfined", pod, set_(["securityContext", "appArmorProfile", "type"], "Unconfined")),
         ("selinux-user", pod, set_(["securityContext", "seLinuxOptions", "user"], "system_u")),
         ("proc-mount", pod, set_(["securityContext", "procMount"], "Unmasked")),
         ("unsafe-sysctl", pod, set_(["securityContext", "sysctls"], [{"name": "kernel.msgmax", "value": "1"}], "pod")),
         ("nfs-volume", pod, add_volume({"name": "nfs", "nfs": {"server": "nfs.example", "path": "/"}})),
         ("host-network-deploy", deployment, set_(["hostNetwork"], True, "pod")),
         ("root-not-helper", pod, set_(["securityContext", "runAsNonRoot"], False, "pod"), "local-path-storage"),
         ("selinux-spc-t", pod, set_(["securityContext", "seLinuxOptions", "type"], "spc_t")),
         ("root-in-velero-not-node-agent", pod, set_(["securityContext", "runAsNonRoot"], False, "pod"), "velero")],
        [("helper-pod-delete-pvc-1", pod, set_(["securityContext", "runAsNonRoot"], False, "pod"), "local-path-storage"),
         ("kube-bench-host-pid", pod, kube_bench(set_(["hostPID"], True, "pod")), "kube-bench"),
         ("velero-node-agent-spc-t", pod, node_agent(set_(["securityContext", "seLinuxOptions", "type"], "spc_t")), "velero"),
         ("velero-hosting-pod-root", pod, velero_hosting_pod(set_(["securityContext", "runAsNonRoot"], False, "pod")), "velero")],
    ),
    "disallow-latest-tag": (
        [("compliant", pod, None),
         ("tagged", pod, set_(["image"], "127.0.0.1:30500/library/alpine:3.22")),
         ("digest-only", pod, set_(["image"], "127.0.0.1:30500/library/alpine@sha256:"
                                   "49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"))],
        [("latest", pod, set_(["image"], "127.0.0.1:30500/library/alpine:latest")),
         ("untagged", pod, set_(["image"], "127.0.0.1:30500/library/alpine")),
         ("untagged-short-name", pod, set_(["image"], "alpine")),
         ("latest-deploy", deployment, set_(["image"], "127.0.0.1:30500/library/alpine:latest"))],
    ),
    "require-resources": (
        [("compliant", pod, None),
         ("compliant-deploy", deployment, None)],
        [("no-resources", pod, delete(["resources"])),
         ("no-cpu-request", pod, delete(["resources", "requests", "cpu"])),
         ("no-memory-request", pod, delete(["resources", "requests", "memory"])),
         ("no-memory-limit", pod, delete(["resources", "limits"])),
         ("init-no-resources", pod, lambda s, m: s.update(initContainers=[
             {k: v for k, v in c0(s).items() if k != "resources"} | {"name": "init"}])),
         ("no-resources-deploy", deployment, delete(["resources"]))],
    ),
    "require-labels": (
        [("compliant", pod, None),
         ("compliant-deploy", deployment, None)],
        [("no-labels", pod, delete(["labels"], "meta")),
         ("empty-name-label", pod, set_(["labels", "app.kubernetes.io/name"], "", "meta")),
         ("no-labels-deploy", deployment, delete(["labels"], "meta"))],
    ),
    "disallow-secret-env": (
        [("compliant", pod, None),
         ("configmap-env", pod, set_(["env"], [{"name": "MODE", "valueFrom": {"configMapKeyRef": {"name": "cfg", "key": "mode"}}}])),
         ("plain-env", pod, set_(["env"], [{"name": "MODE", "value": "prod"}])),
         ("secret-volume", pod, add_volume({"name": "creds", "secret": {"secretName": "db"}})),
         ("compliant-deploy", deployment, None)],
        [("secret-key-ref", pod, set_(["env"], [{"name": "DB_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "db", "key": "password"}}}])),
         ("env-from-secret", pod, set_(["envFrom"], [{"secretRef": {"name": "db"}}])),
         ("init-secret-key-ref", pod, lambda s, m: s.update(initContainers=[
             c0(s) | {"name": "init", "env": [{"name": "TOKEN", "valueFrom": {"secretKeyRef": {"name": "t", "key": "t"}}}]}])),
         ("secret-key-ref-deploy", deployment, set_(["env"], [{"name": "DB_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "db", "key": "password"}}}]))],
    ),
    "restrict-image-registries": (
        [("compliant", pod, None),
         ("zarf-registry", pod, set_(["image"], "127.0.0.1:31999/library/alpine:3.22")),
         # platform-bootstrap-images exception: listed repos, platform namespaces
         ("argocd-upstream", pod, set_(["image"], ARGOCD), "argocd"),
         ("zot-upstream", pod, set_(["image"], "ghcr.io/project-zot/zot:v2.1.23"), "zot"),
         ("velero-upstream", pod, set_(["image"], VELERO), "velero"),
         # kube-bench-image exception: the pinned scanner, in its namespace, with its label
         ("kube-bench-image", pod, kube_bench(set_(["image"], KUBE_BENCH)), "kube-bench")],
        [("docker-hub", pod, set_(["image"], "docker.io/library/alpine:3.22")),
         ("short-name", pod, set_(["image"], "alpine:3.22")),
         ("lookalike-host", pod, set_(["image"], "127.0.0.1:30500.evil.example/library/alpine:3.22")),
         ("other-port", pod, set_(["image"], "127.0.0.1:5000/library/alpine:3.22")),
         ("init-untrusted", pod, lambda s, m: s.update(initContainers=[
             c0(s) | {"name": "init", "image": "docker.io/library/busybox:1.37.0"}])),
         ("docker-hub-deploy", deployment, set_(["image"], "docker.io/library/alpine:3.22")),
         # the exception adds exact repositories only, in its namespaces only
         ("argocd-image-in-apps", pod, set_(["image"], ARGOCD)),
         ("velero-image-in-apps", pod, set_(["image"], VELERO)),
         ("other-image-in-argocd", pod, set_(["image"], "docker.io/library/alpine:3.22"), "argocd"),
         ("lookalike-repo-in-argocd", pod, set_(["image"], "quay.io/argoproj/argocd-evil:v1"), "argocd"),
         ("kube-bench-image-in-apps", pod, kube_bench(set_(["image"], KUBE_BENCH))),
         ("kube-bench-image-without-label", pod, set_(["image"], KUBE_BENCH), "kube-bench"),
         ("other-image-as-kube-bench", pod, kube_bench(set_(["image"], "docker.io/library/alpine:3.22")), "kube-bench"),
         ("kube-bench-image-by-tag", pod, kube_bench(set_(["image"], "docker.io/aquasec/kube-bench:v0.16.0")), "kube-bench"),
         ("allowed-image-untrusted-sidecar", pod, lambda s, m: (
             c0(s).update(image=ARGOCD),
             s["containers"].append(c0(s) | {"name": "sidecar", "image": "docker.io/library/alpine:3.22"})),
          "argocd")],
    ),
}


def main():
    for policy, groups in CASES.items():
        passing, failing, skipped = (list(groups) + [[]])[:3]
        d = HERE / policy
        d.mkdir(exist_ok=True)
        docs, results = [], []
        for expected, cases in (("pass", passing), ("fail", failing), ("skip", skipped)):
            for name, kind, change, *ns in cases:
                doc = kind(name, change, *ns)
                if doc["kind"] == "Deployment":
                    doc["spec"]["template"]["metadata"].pop("name")
                docs.append(doc)
                results.append({"policy": policy, "resources": [name],
                                "kind": doc["kind"], "result": expected})
        (d / "resources.yaml").write_text(
            "# Generated by tests/policies/generate.py; do not edit.\n"
            + yaml.safe_dump_all(docs, sort_keys=False))
        test = {
            "apiVersion": "cli.kyverno.io/v1alpha1",
            "kind": "Test",
            "metadata": {"name": policy},
            "policies": [f"../../../gitops/policies/{policy}.yaml"],
            "resources": ["resources.yaml"],
            **({"exceptions": [f"../../../gitops/policies/{e}" for e in EXCEPTIONS[policy]]}
               if policy in EXCEPTIONS else {}),
            "results": results,
        }
        (d / "kyverno-test.yaml").write_text(
            "# Generated by tests/policies/generate.py; do not edit.\n"
            + yaml.safe_dump(test, sort_keys=False))
        print(f"{policy}: {len(passing)} pass, {len(failing)} fail, {len(skipped)} skip cases")


if __name__ == "__main__":
    main()
