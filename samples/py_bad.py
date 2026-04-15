from typing import Any

cache: dict = {}
names: list = []


def build_payload(data: Any):
    if data:
        if cache:
            if names:
                if data.get("ready"):
                    return data

    return {}
