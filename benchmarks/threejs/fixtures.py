"""Write identical Float64 projection inputs and algebraic oracles for Julia/JS."""

import argparse
import json
import math
from pathlib import Path


def projection_case(count: int) -> dict:
    xs = [0.3 + 0.3 * (1 + math.sin(i * 0.73)) / 2 for i in range(count)]
    ys = [0.3 + 0.3 * (1 + math.cos(i * 0.41)) / 2 for i in range(count)]
    truth = [-2.0 - 0.6 * (1 + math.sin(i * 0.31)) / 2 for i in range(count)]
    parameters = [z + 0.25 * math.cos(i * 0.19) for i, z in enumerate(truth)]
    scale = math.sqrt(3.0)  # tan(pi/6)^-1 for a 60-degree perspective camera.
    target_x = [-scale * x / z for x, z in zip(xs, truth)]
    target_y = [-scale * y / z for y, z in zip(ys, truth)]
    dx = [-scale * x / z - target for x, z, target in zip(xs, parameters, target_x)]
    dy = [-scale * y / z - target for y, z, target in zip(ys, parameters, target_y)]
    gradient = [(ex * scale * x + ey * scale * y) / (count * z * z)
                for ex, ey, x, y, z in zip(dx, dy, xs, ys, parameters)]
    loss = sum(x * x + y * y for x, y in zip(dx, dy)) / (2 * count)
    return {"count": count, "x": xs, "y": ys, "truth": truth,
            "parameters": parameters, "target_x": target_x, "target_y": target_y,
            "expected_loss": loss, "expected_gradient": gradient}


def write_fixture(output: Path, name: str, fixture: dict) -> None:
    (output / f"{name}.json").write_text(json.dumps(fixture, indent=2) + "\n")
    lines = [f"{key} = {json.dumps(value)}" for key, value in fixture.items() if key != "cases"]
    for case in fixture["cases"]:
        lines.extend(["", "[[cases]]"])
        lines.extend(f"{key} = {json.dumps(value)}" for key, value in case.items())
    (output / f"{name}.toml").write_text("\n".join(lines) + "\n")


def browser_case(count: int, mode: str) -> dict:
    columns = math.ceil(math.sqrt(count))
    rows = math.ceil(count / columns)
    spacing = min(1.8 / columns, 1.8 / rows)
    extent = 0.35 * spacing
    centers = [coordinate for i in range(count)
               for coordinate in (-0.9 + (i % columns + 0.5) * 1.8 / columns,
                                  -0.9 + (i // columns + 0.5) * 1.8 / rows, 0.0)]
    return {"id": f"{mode}-{count}", "mode": mode, "count": count,
            "positions": [-extent, -extent, 0.0, extent, -extent, 0.0, 0.0, extent, 0.0],
            "normals": [0.0, 0.0, 1.0] * 3, "indices": [0, 1, 2], "centers": centers,
            "amplitude": 0.12 * spacing}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    near, far, scale = 0.1, 20.0, math.sqrt(3.0)
    matrix = [scale, 0.0, 0.0, 0.0, 0.0, scale, 0.0, 0.0,
              0.0, 0.0, -(far + near) / (far - near), -1.0,
              0.0, 0.0, -2 * far * near / (far - near), 0.0]
    fixture = {"schema": 1, "samples": 21, "warmup": 5, "matrix": matrix,
               "cases": [projection_case(count) for count in (16, 64, 256, 1024)]}
    write_fixture(args.output, "projection", fixture)
    write_fixture(args.output, "browser", {
        "schema": 1, "width": 256, "height": 256, "samples": 21, "warmup": 5,
        "frames_per_sample": 8,
        "color": [0.2, 0.4, 0.6], "background": [0.0, 0.0, 0.0],
        "cases": [browser_case(count, mode) for count in (16, 128, 512)
                  for mode in ("static", "instanced", "dynamic")],
    })


if __name__ == "__main__":
    main()
