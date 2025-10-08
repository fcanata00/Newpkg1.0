#!/usr/bin/env python3
"""
deps.py - dependency resolver for newpkg

Features:
- parse metafiles (YAML) from /usr/ports or explicit path
- build dependency graph using networkx
- interactive resolution of optional deps
- export graph to JSON or DOT
- persist cache to /var/lib/newpkg/depgraph.json
- detect cycles, compute install/build order (topological sort)
- detect orphans (compare graph with installed packages via db.sh)
- integrate with hooks in /etc/newpkg/hooks/deps/
- logging to /var/log/newpkg/deps.log

Usage:
  deps.py resolve <package>           # resolve and print full dependency list
  deps.py order <package>             # show build/install order (topo)
  deps.py missing <package>           # list missing deps (not installed)
  deps.py graph --format json|dot -o file
  deps.py check <package>             # check installed status of deps
  deps.py clean                       # depclean: remove orphaned deps suggestion
  deps.py rebuild <package>           # mark dependents for rebuild (prints list)
  deps.py sync                        # rebuild graph cache from /usr/ports
  deps.py export <file> --format json|dot
  deps.py help

Notes:
- Requires `PyYAML` and `networkx` Python packages.
- Interacts with /usr/ports (search) and /var/lib/newpkg/db via db.sh CLI.
"""

from __future__ import annotations
import argparse
import json
import logging
import os
import subprocess
import sys
import time
from typing import Dict, List, Set, Tuple, Optional

try:
    import yaml
except Exception as e:
    print("Missing dependency: PyYAML (yaml). Install with `pip install pyyaml`.", file=sys.stderr)
    sys.exit(1)

try:
    import networkx as nx
except Exception:
    print("Missing dependency: networkx. Install with `pip install networkx`.", file=sys.stderr)
    sys.exit(1)

# Directories / files
CONFIG_FILE = "/etc/newpkg/newpkg.yaml"
PORTS_DIR = "/usr/ports"
DEPGRAPH_CACHE = "/var/lib/newpkg/depgraph.json"
LOG_DIR = "/var/log/newpkg"
LOG_FILE = os.path.join(LOG_DIR, "deps.log")
DB_CLI = "/usr/lib/newpkg/db.sh"  # path to db.sh CLI; adjust if different

# Behavior defaults (can be overridden by CONFIG_FILE)
DEFAULTS = {
    "resolve_optional": False,
    "auto_install": False,
    "cache_graph": True,
    "use_provides": True,
    "prefer_binary": True,
    "prefer_cached_graph": True,
    "search_ports_paths": [PORTS_DIR],
}

# Ensure dirs
os.makedirs(os.path.dirname(DEPGRAPH_CACHE), exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

# Logging
logger = logging.getLogger("newpkg-deps")
logger.setLevel(logging.INFO)
fh = logging.FileHandler(LOG_FILE)
fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
fh.setFormatter(fmt)
logger.addHandler(fh)
# console handler
ch = logging.StreamHandler()
ch.setFormatter(fmt)
logger.addHandler(ch)


def run_hooks(hookname: str, *args):
    hooks_dir = f"/etc/newpkg/hooks/deps/{hookname}"
    if not os.path.isdir(hooks_dir):
        return
    for entry in sorted(os.listdir(hooks_dir)):
        path = os.path.join(hooks_dir, entry)
        if os.access(path, os.X_OK) and os.path.isfile(path):
            logger.info(f"Running hook {hookname}: {path}")
            try:
                subprocess.run([path] + list(args), check=False)
            except Exception as e:
                logger.warning(f"Hook {path} failed: {e}")


def load_yaml_config(path: str = CONFIG_FILE) -> Dict:
    if not os.path.isfile(path):
        logger.info(f"No config at {path}, using defaults")
        return DEFAULTS.copy()
    try:
        with open(path, "r") as f:
            conf = yaml.safe_load(f) or {}
            deps_conf = conf.get("deps", {})
            merged = DEFAULTS.copy()
            merged.update(deps_conf)
            # also read ports search paths if provided
            if "ports" in conf:
                merged["search_ports_paths"] = conf.get("ports", {}).get("paths", [PORTS_DIR])
            return merged
    except Exception as e:
        logger.error(f"Failed to parse config {path}: {e}")
        return DEFAULTS.copy()


def call_db_query(pkgname: str) -> Optional[Dict]:
    """
    Calls db.sh query <pkg> --json and returns parsed JSON if installed
    """
    try:
        # try by name (db.sh query <pkg> --json)
        res = subprocess.run([DB_CLI, "query", pkgname, "--json"], capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip():
            # db.sh may output either a single manifest JSON or an array (index based)
            try:
                parsed = json.loads(res.stdout)
                # If it's an array, return first
                if isinstance(parsed, list) and parsed:
                    return parsed[0]
                elif isinstance(parsed, dict):
                    return parsed
            except Exception:
                # fallback: db.sh may print multiple JSON objects; try to read first file path
                return None
        return None
    except FileNotFoundError:
        logger.warning(f"db CLI not found at {DB_CLI}; cannot check installed packages automatically.")
        return None


def db_revdeps(pkgname: str) -> List[str]:
    """
    Calls db.sh revdeps <pkg> and returns list of "name-version"
    """
    try:
        res = subprocess.run([DB_CLI, "revdeps", pkgname], capture_output=True, text=True)
        if res.returncode == 0:
            lines = [ln.strip() for ln in res.stdout.splitlines() if ln.strip()]
            return lines
        return []
    except FileNotFoundError:
        logger.warning("db CLI not found; revdeps not available.")
        return []


def find_metafile_for_name(name: str) -> Optional[str]:
    """
    Search /usr/ports tree for a meta file matching package name.
    Looks for files named meta.yaml, meta.yml, package.yaml etc., and tries to match .name
    """
    exts = ("meta.yaml", "meta.yml", "meta.json", "meta")
    for base in DEFAULTS["search_ports_paths"]:
        for root, dirs, files in os.walk(base):
            for fn in files:
                if fn.lower().endswith((".yaml", ".yml", ".json", ".meta")) or fn in exts:
                    path = os.path.join(root, fn)
                    try:
                        with open(path, "r") as fh:
                            content = fh.read()
                            try:
                                if fn.endswith((".yaml", ".yml")):
                                    parsed = yaml.safe_load(content)
                                else:
                                    # try json
                                    parsed = json.loads(content)
                            except Exception:
                                parsed = None
                            if isinstance(parsed, dict):
                                n = parsed.get("name") or parsed.get("package") or parsed.get("pkgname")
                                if n == name:
                                    return path
                    except Exception:
                        continue
    return None


def parse_metafile(path_or_name: str) -> Optional[Dict]:
    """
    Accepts a path to a metafile or a package name. Returns parsed dict or None.
    """
    path = path_or_name
    if not os.path.isfile(path_or_name):
        # try to find by name in ports tree
        found = find_metafile_for_name(path_or_name)
        if not found:
            logger.debug(f"Metafile for '{path_or_name}' not found in ports tree.")
            return None
        path = found
    try:
        with open(path, "r") as f:
            if path.endswith((".yaml", ".yml")):
                data = yaml.safe_load(f)
            else:
                # try YAML first anyway
                try:
                    data = yaml.safe_load(f)
                except Exception:
                    data = json.load(f)
        if not isinstance(data, dict):
            logger.debug(f"Parsed metafile is not dict: {path}")
            return None
        # normalize structure
        # expected keys: name/version/build.depends/runtime.depends/provides/optional/environment
        return data
    except Exception as e:
        logger.error(f"Failed to parse metafile {path}: {e}")
        return None


class DepResolver:
    def __init__(self, config: Dict, cache_path: str = DEPGRAPH_CACHE, aggressive_cache: bool = True):
        self.config = config
        self.graph = nx.DiGraph()
        self.cache_path = cache_path
        self.aggressive_cache = aggressive_cache and bool(self.config.get("cache_graph", True))
        self.loaded_from_cache = False
        if self.aggressive_cache:
            self._try_load_cache()

    def _try_load_cache(self):
        try:
            if os.path.isfile(self.cache_path):
                with open(self.cache_path, "r") as fh:
                    data = json.load(fh)
                # rebuild graph
                self.graph.clear()
                for node, meta in data.items():
                    self.graph.add_node(node, **meta.get("attrs", {}))
                for node, meta in data.items():
                    for dep in meta.get("deps", []):
                        # dep is simple string (name)
                        self.graph.add_edge(node, dep)
                logger.info(f"Loaded dependency graph cache from {self.cache_path}")
                self.loaded_from_cache = True
        except Exception as e:
            logger.warning(f"Failed to load depgraph cache: {e}")
            self.loaded_from_cache = False

    def persist_cache(self):
        try:
            out = {}
            for n in self.graph.nodes:
                attrs = dict(self.graph.nodes[n])
                deps = list(self.graph.successors(n))
                out[n] = {"attrs": attrs, "deps": deps}
            tmp = self.cache_path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(out, fh, indent=2)
            os.replace(tmp, self.cache_path)
            logger.info(f"Persisted dependency graph to {self.cache_path}")
        except Exception as e:
            logger.error(f"Failed to persist cache: {e}")

    def add_package_from_metafile(self, path_or_name: str) -> Optional[str]:
        meta = parse_metafile(path_or_name)
        if not meta:
            logger.debug(f"No metafile parsed for {path_or_name}")
            return None
        name = meta.get("name") or meta.get("package") or meta.get("pkgname")
        if not name:
            logger.warning(f"No name field in metafile {path_or_name}")
            return None
        # standardize dependency listing
        build_deps = []
        run_deps = []
        optional = []
        provides = meta.get("provides") or []
        # gather build deps
        b = meta.get("build", {}) or {}
        if isinstance(b, dict):
            build_deps = b.get("depends") or b.get("depends_on") or []
            optional = b.get("optional") or optional
        # run deps
        r = meta.get("runtime", {}) or {}
        if isinstance(r, dict):
            run_deps = r.get("depends") or []
        # flatten and normalize strings
        def norm_list(lst):
            out = []
            if not lst:
                return out
            for it in lst:
                if isinstance(it, str):
                    # strip version constraints like libfoo>=1.0 -> libfoo
                    out.append(it.split()[0].split(">=")[0].split("<=")[0].split("==")[0].split(">")[0].split("<")[0])
                elif isinstance(it, dict) and "name" in it:
                    out.append(it["name"])
            return out
        build_deps = norm_list(build_deps)
        run_deps = norm_list(run_deps)
        optional = norm_list(optional)
        # add node and edges: node -> deps (edges node -> dep); for topological sort we may want reverse, but stick with this (successor = dependency)
        self.graph.add_node(name, version=meta.get("version"), origin=meta.get("origin", ""), provides=provides, optional=optional)
        # add edges
        for d in set(build_deps + run_deps):
            if d == name:
                continue
            self.graph.add_node(d)
            self.graph.add_edge(name, d)
        # optional deps recorded as node attribute for later interactive prompt
        if optional:
            self.graph.nodes[name]["optional"] = optional
        return name

    def build_graph_from_ports(self):
        """
        Walk ports tree and parse each metafile (may be slow). Uses parse_metafile.
        """
        run_hooks("pre-deps-sync")
        logger.info("Scanning ports tree to build dependency graph...")
        count = 0
        for base in self.config.get("search_ports_paths", [PORTS_DIR]):
            for root, dirs, files in os.walk(base):
                for fn in files:
                    if fn.lower().endswith((".yaml", ".yml")):
                        full = os.path.join(root, fn)
                        try:
                            with open(full, "r") as fh:
                                doc = yaml.safe_load(fh)
                            if isinstance(doc, dict):
                                # attempt to add
                                name = doc.get("name") or doc.get("package") or doc.get("pkgname")
                                if name:
                                    self.add_package_from_metafile(full)
                                    count += 1
                        except Exception:
                            continue
        logger.info(f"Scanned ports tree, added {count} packages to graph")
        run_hooks("post-deps-sync")
        if self.config.get("cache_graph", True):
            self.persist_cache()

    def resolve(self, root_pkg: str, include_optional_prompt: bool = True) -> Tuple[List[str], List[str]]:
        """
        Resolve dependencies recursively for root_pkg.
        Returns (resolved_list_in_topo_order, cycles_list)
        If optional deps exist, ask interactively (include_optional_prompt).
        """
        if root_pkg not in self.graph.nodes:
            # try to add from metafile (search ports)
            added = self.add_package_from_metafile(root_pkg)
            if not added:
                logger.warning(f"Package '{root_pkg}' not found in graph or ports tree.")
                return [], []
        # collect all dependencies via DFS
        deps_set: Set[str] = set()
        stack = [root_pkg]
        visited = set()
        optional_to_ask = {}

        while stack:
            cur = stack.pop()
            if cur in visited:
                continue
            visited.add(cur)
            # dependencies are successors in this graph (node -> dep)
            for dep in self.graph.successors(cur):
                if dep == cur:
                    continue
                deps_set.add(dep)
                stack.append(dep)
            # collect optional if present
            opt = self.graph.nodes[cur].get("optional") or []
            if opt:
                optional_to_ask[cur] = opt

        # interactive optional deps prompt
        selected_optional = set()
        if optional_to_ask and include_optional_prompt and self.config.get("resolve_optional", False):
            for parent, opts in optional_to_ask.items():
                for o in opts:
                    prompt = f"Package {parent} has optional dependency '{o}'. Include it? [y/N]: "
                    try:
                        ans = input(prompt).strip().lower()
                    except KeyboardInterrupt:
                        ans = "n"
                    if ans in ("y", "yes"):
                        selected_optional.add(o)
                        # add to graph if not present ( attempt to parse metafile )
                        if o not in self.graph.nodes:
                            self.add_package_from_metafile(o)
                        # add transitive deps of that optional
                        stack = [o]
                        while stack:
                            c = stack.pop()
                            for dep in self.graph.successors(c):
                                if dep not in deps_set:
                                    deps_set.add(dep)
                                    stack.append(dep)

        # Now we have set of deps; build subgraph with root_pkg + deps_set
        sub_nodes = set(deps_set)
        sub_nodes.add(root_pkg)
        subg = self.graph.subgraph(sub_nodes).copy()
        # detect cycles
        cycles = list(nx.simple_cycles(subg))
        if cycles:
            logger.error(f"Dependency cycles detected: {cycles}")
            return [], [','.join(c) for c in cycles]
        # compute topological order: ensure dependencies come before dependents for build ordering we need reverse topological
        try:
            topo = list(nx.topological_sort(subg))
            # For build order: build dependencies first; we want order where dependencies appear before dependents.
            # topological_sort gives that: nodes with no incoming edges first (leaves), but our edges are node->dep, so edges from package to its dep.
            # To get build order we actually need reverse of topological_sort (so dependencies first):
            build_order = topo[::-1]
        except Exception as e:
            logger.error(f"Topological sort failed: {e}")
            return [], []
        return build_order, []

    def missing_deps(self, root_pkg: str) -> List[str]:
        """
        Returns a list of dependencies that are not installed according to db.sh
        """
        order, cycles = self.resolve(root_pkg, include_optional_prompt=False)
        if cycles:
            logger.error("Cannot compute missing deps due to cycles.")
            return []
        missing = []
        for pkg in order:
            # skip the root package itself
            if pkg == root_pkg:
                continue
            installed = call_db_query(pkg)
            if not installed:
                missing.append(pkg)
        return missing

    def install_order(self, root_pkg: str, skip_installed: bool = True) -> List[str]:
        """
        Returns install/build order; by default skips packages already installed
        """
        order, cycles = self.resolve(root_pkg, include_optional_prompt=False)
        if cycles:
            raise RuntimeError(f"Cycles detected: {cycles}")
        final = []
        for pkg in order:
            if pkg == root_pkg:
                continue
            if skip_installed:
                if call_db_query(pkg):
                    logger.debug(f"Skipping installed package {pkg}")
                    continue
            final.append(pkg)
        # finally append root_pkg if not installed
        if not (skip_installed and call_db_query(root_pkg)):
            final.append(root_pkg)
        return final

    def detect_orphans(self) -> List[str]:
        """
        Returns list of packages that appear installed in db.sh but are not required by any other package (true orphans).
        Uses db.sh to list installed packages.
        """
        # get list from db: db.sh list --json
        try:
            res = subprocess.run([DB_CLI, "list", "--json"], capture_output=True, text=True)
            if res.returncode != 0 or not res.stdout.strip():
                logger.warning("db.sh list returned no data or failed; cannot detect orphans.")
                return []
            installed = json.loads(res.stdout)
            installed_names = [it.get("name") for it in installed if isinstance(it, dict) and it.get("name")]
        except Exception:
            logger.warning("Failed to query db for installed packages.")
            installed_names = []

        # build reverse-dependency map from graph: who depends on whom?
        revdeps_map = {}
        for node in self.graph.nodes:
            revdeps_map[node] = set()
        for src, dst in self.graph.edges:
            # src depends on dst
            revdeps_map.setdefault(dst, set()).add(src)

        orphans = []
        for name in installed_names:
            # if no one depends on it and it's not in our graph as a dependency of anything
            deps_of_me = revdeps_map.get(name, set())
            if not deps_of_me:
                orphans.append(name)
        return orphans

    def mark_for_rebuild(self, pkg: str) -> List[str]:
        """
        Given a package, find all packages that (directly or indirectly) depend on it.
        Uses db_revdeps (db.sh revdeps) as authoritative and also graph traversal.
        Returns list of package names to rebuild (ordered: deepest dependents first).
        """
        # try db_revdeps first
        revdeps_from_db = db_revdeps(pkg)
        # revdeps_from_db are name-version strings; strip version to get name
        parsed = [r.split("-", 1)[0] for r in revdeps_from_db]
        # also use graph traversal
        dependents = set()
        if pkg in self.graph.nodes:
            # nodes that have a path from node -> ... -> pkg? but our edges are node->dep (source depends on dest),
            # so we need nodes that can reach 'pkg' via edges: find predecessors repeatedly
            for n in self.graph.nodes:
                if nx.has_path(self.graph, n, pkg):
                    dependents.add(n)
        dependents.update(parsed)
        # order: we want to rebuild dependencies of dependents first? Typically rebuild dependents after rebuilding pkg.
        # produce list sorted by distance from pkg descending (closest dependents first)
        try:
            distances = {}
            for d in dependents:
                try:
                    distances[d] = nx.shortest_path_length(self.graph, d, pkg)
                except Exception:
                    distances[d] = 0
            ordered = sorted(list(dependents), key=lambda x: distances.get(x, 0), reverse=True)
        except Exception:
            ordered = list(dependents)
        return ordered

    def export_graph(self, out_path: str, fmt: str = "json"):
        if fmt == "json":
            out = {}
            for n in self.graph.nodes:
                out[n] = {
                    "attrs": dict(self.graph.nodes[n]),
                    "deps": list(self.graph.successors(n))
                }
            with open(out_path, "w") as fh:
                json.dump(out, fh, indent=2)
            logger.info(f"Graph exported to {out_path} (json)")
        elif fmt == "dot":
            try:
                from networkx.drawing.nx_pydot import write_dot
            except Exception:
                logger.error("dot export requires pydot or pygraphviz; ensure they are installed.")
                raise
            write_dot(self.graph, out_path)
            logger.info(f"Graph exported to {out_path} (dot)")
        else:
            logger.error("Unsupported format: " + fmt)
            raise ValueError("Unsupported format")

    def sync_from_ports(self):
        """
        Rebuild graph by scanning ports tree (forced).
        """
        self.graph = nx.DiGraph()
        self.build_graph_from_ports()
        if self.config.get("cache_graph", True):
            self.persist_cache()


def main_cli():
    parser = argparse.ArgumentParser(prog="deps.py", description="Dependency resolver for newpkg")
    sub = parser.add_subparsers(dest="cmd")

    sub.resolve = sub.add_parser("resolve", help="Resolve dependencies for package")
    sub.resolve.add_argument("package", help="package name or metafile path")
    sub.resolve.add_argument("--no-prompt", action="store_true", help="do not prompt for optional deps")

    sub.order = sub.add_parser("order", help="Show build/install order")
    sub.order.add_argument("package", help="package name or metafile path")
    sub.order.add_argument("--skip-installed", action="store_true", help="skip packages already installed")

    sub.missing = sub.add_parser("missing", help="List missing deps (not installed)")
    sub.missing.add_argument("package", help="package name or metafile path")

    sub.graph = sub.add_parser("graph", help="Export dependency graph")
    sub.graph.add_argument("--format", choices=["json", "dot"], default="json")
    sub.graph.add_argument("-o", "--out", required=True, help="output file path")

    sub.check = sub.add_parser("check", help="Check if dependencies of a package are installed")
    sub.check.add_argument("package", help="package name or metafile path")

    sub.clean = sub.add_parser("clean", help="Depclean: show orphaned packages")
    sub.rebuild = sub.add_parser("rebuild", help="List packages that should be rebuilt due to changes")
    sub.rebuild.add_argument("package", help="package name")

    sub.sync = sub.add_parser("sync", help="Rebuild/resync graph cache from ports tree")

    args = parser.parse_args()

    config = load_yaml_config(CONFIG_FILE)
    resolver = DepResolver(config, cache_path=DEPGRAPH_CACHE, aggressive_cache=config.get("prefer_cached_graph", True))

    if args.cmd == "resolve":
        include_prompt = not args.no_prompt
        run_hooks("pre-deps-resolve", args.package)
        order, cycles = resolver.resolve(args.package, include_optional_prompt=include_prompt)
        run_hooks("post-deps-resolve", args.package)
        if cycles:
            print("Cycles:", cycles)
            sys.exit(2)
        print("Resolved order (dependencies first):")
        for p in order:
            print(p)
    elif args.cmd == "order":
        try:
            skip_inst = args.skip_installed
            order = resolver.install_order(args.package, skip_installed=skip_inst)
            print("\n".join(order))
        except Exception as e:
            logger.error(str(e))
            sys.exit(1)
    elif args.cmd == "missing":
        miss = resolver.missing_deps(args.package)
        if miss:
            print("\n".join(miss))
        else:
            print("No missing dependencies (or failed to resolve).")
    elif args.cmd == "graph":
        out = args.out
        fmt = args.format
        try:
            resolver.export_graph(out, fmt)
        except Exception as e:
            logger.error(f"Failed to export graph: {e}")
            sys.exit(1)
    elif args.cmd == "check":
        run_hooks("pre-deps-resolve", args.package)
        miss = resolver.missing_deps(args.package)
        run_hooks("post-deps-resolve", args.package)
        if miss:
            print("Missing dependencies:")
            for m in miss:
                print(" -", m)
            sys.exit(1)
        else:
            print("All dependencies present.")
    elif args.cmd == "clean":
        orphans = resolver.detect_orphans()
        if not orphans:
            print("No orphans detected.")
            sys.exit(0)
        print("Orphan packages (installed but no reverse-deps):")
        for o in orphans:
            print(" -", o)
        # No automatic removal; user must call remove.sh
    elif args.cmd == "rebuild":
        plist = resolver.mark_for_rebuild(args.package)
        if plist:
            print("Packages to rebuild (dependents of {}):".format(args.package))
            for p in plist:
                print(" -", p)
        else:
            print("No dependents detected.")
    elif args.cmd == "sync":
        resolver.sync_from_ports()
        print("Graph rebuilt and cached.")
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main_cli()
