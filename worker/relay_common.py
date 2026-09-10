"""App-authored request errors and local path checks shared by the worker modules."""
from pathlib import Path


class WorkerRequestError(ValueError):
    """An app-authored error safe to show; dependency exception text stays private."""


def local_path(value, directory=False):
    path = Path(value).expanduser()
    if not path.is_absolute() or not (path.is_dir() if directory else path.is_file()):
        raise WorkerRequestError("ローカルファイルが見つかりません。モデルと音声の設定を確認してください。")
    return path.resolve()
