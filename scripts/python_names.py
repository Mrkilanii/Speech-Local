"""Generate the name table code dictation matches spoken words against.

Run at development time, never by the app: the app has no network and no
Python. The output is a Swift source file committed alongside this script, so
a fresh clone builds without running it.

    python3 -m venv /tmp/pynames
    /tmp/pynames/bin/pip install numpy pandas matplotlib seaborn scikit-learn scipy torch
    /tmp/pynames/bin/python scripts/python_names.py > Sources/SpeechLocalCore/PythonNames.swift

Only NAMES are taken — no docstrings or signatures — and for each whether it is
callable, because that decides whether "plt dot show" becomes `plt.show()` or
"df dot shape" stays `df.shape`. Names beginning with an underscore are private
and skipped.

Each line of the table is `owner kind name`: the owner is the alias a script
reaches the name through (`np`, `pd`, `DataFrame`, `builtins`), and the kind is
`f` for callable, `c` for a class, `a` for anything else.
"""

import builtins
import importlib
import inspect
import keyword
import sys

# Owner label -> dotted path to import and list. The labels are what people
# type: `np.`, `pd.`, `plt.`, so matching after a dot can be scoped to them.
SOURCES = {
    # The standard library a data script touches.
    "builtins": "builtins",
    "csv": "csv",
    "json": "json",
    "math": "math",
    "random": "random",
    "os": "os",
    "os.path": "os.path",
    "sys": "sys",
    "re": "re",
    "datetime": "datetime",
    "time": "time",
    "collections": "collections",
    "itertools": "itertools",
    "statistics": "statistics",
    "pathlib": "pathlib",
    "Path": "pathlib.Path",
    "str": "builtins.str",
    "list": "builtins.list",
    "dict": "builtins.dict",
    "set": "builtins.set",
    "file": "io.TextIOWrapper",
    # Data analysis.
    "np": "numpy",
    "random.np": "numpy.random",
    "linalg": "numpy.linalg",
    "ndarray": "numpy.ndarray",
    "pd": "pandas",
    "DataFrame": "pandas.DataFrame",
    "Series": "pandas.Series",
    "plt": "matplotlib.pyplot",
    "Axes": "matplotlib.axes.Axes",
    "Figure": "matplotlib.figure.Figure",
    "sns": "seaborn",
    "scipy.stats": "scipy.stats",
    # Machine learning.
    "sklearn": "sklearn",
    "model_selection": "sklearn.model_selection",
    "preprocessing": "sklearn.preprocessing",
    "linear_model": "sklearn.linear_model",
    "metrics": "sklearn.metrics",
    "ensemble": "sklearn.ensemble",
    "tree": "sklearn.tree",
    "cluster": "sklearn.cluster",
    "neighbors": "sklearn.neighbors",
    "svm": "sklearn.svm",
    "decomposition": "sklearn.decomposition",
    "pipeline": "sklearn.pipeline",
    "impute": "sklearn.impute",
    "torch": "torch",
    "Tensor": "torch.Tensor",
    "nn": "torch.nn",
    "F": "torch.nn.functional",
    "optim": "torch.optim",
    "utils.data": "torch.utils.data",
}

# Every fitted estimator shares these; listing them once under `model` lets
# "model dot fit" resolve without knowing which estimator the variable holds.
ESTIMATOR = ["fit", "predict", "predict_proba", "score", "transform",
             "fit_transform", "inverse_transform", "get_params", "set_params"]
TORCH_MODULE = ["forward", "parameters", "train", "eval", "to", "zero_grad",
                "state_dict", "load_state_dict", "step", "backward", "item"]


def resolve(path):
    parts = path.split(".")
    for cut in range(len(parts), 0, -1):
        try:
            obj = importlib.import_module(".".join(parts[:cut]))
        except ImportError:
            continue
        for attribute in parts[cut:]:
            obj = getattr(obj, attribute)
        return obj
    raise ImportError(path)


def kind(value):
    if inspect.isclass(value):
        return "c"
    if callable(value):
        return "f"
    return "a"


def main():
    rows = set()
    for owner, path in SOURCES.items():
        try:
            obj = resolve(path)
        except Exception as error:  # a missing library skips, loudly
            print(f"skipped {path}: {error}", file=sys.stderr)
            continue
        for name in dir(obj):
            if name.startswith("_"):
                continue
            try:
                value = getattr(obj, name)
            except Exception:
                continue
            rows.add((owner, kind(value), name))
        if inspect.ismodule(obj) and "." in path and owner != path:
            rows.add(("module", "a", path.split(".")[-1]))
    for top in ["numpy", "pandas", "matplotlib", "pyplot", "seaborn", "sklearn",
                "scipy", "torch", "csv", "json", "math", "random", "os", "sys",
                "re", "datetime", "time", "collections", "itertools",
                "statistics", "pathlib", "functional", "stats", "optim", "nn"]:
        rows.add(("module", "a", top))
    for name in ESTIMATOR + TORCH_MODULE:
        rows.add(("model", "f", name))
    for name in keyword.kwlist:
        rows.add(("keyword", "a", name))

    versions = []
    for module in ["numpy", "pandas", "matplotlib", "seaborn", "sklearn", "scipy", "torch"]:
        try:
            versions.append(f"{module} {importlib.import_module(module).__version__}")
        except Exception:
            pass

    body = "\n".join(" ".join(row) for row in sorted(rows))
    print("// GENERATED by scripts/python_names.py — do not edit by hand.")
    print(f"// Python {sys.version.split()[0]}; {', '.join(versions)}.")
    print(f"// {len(rows)} names.")
    print()
    print("enum PythonNames {")
    print("    /// `owner kind name` per line. One string literal, not an array")
    print("    /// literal: thousands of array elements make the type checker crawl.")
    print('    static let table = #"""')
    print(body)
    print('"""#')
    print("}")


if __name__ == "__main__":
    main()
