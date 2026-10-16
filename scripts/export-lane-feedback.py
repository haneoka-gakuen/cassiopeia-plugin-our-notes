#!/usr/bin/env python3
"""Export source lane ParticleSystems and their owner lifetime for renderers."""

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalize(value):
    if isinstance(value, dict):
        return {key: str(item) if key in ("m_PathID", "pathId") and isinstance(item, int)
                else normalize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def source_objects(root, asset):
    path = root / "metadata/sources" / (asset + ".json")
    metadata = json.loads(path.read_bytes())
    archive = metadata["objectArchive"]
    encoded = (root / archive["path"]).read_bytes()
    if digest(encoded) != archive["sha256"]:
        raise ValueError(f"Source archive hash mismatch: {asset}")
    rows = [json.loads(line) for line in gzip.decompress(encoded).splitlines()]
    provenance = {
        "asset": asset,
        "metadataSha256": digest(path.read_bytes()),
        "archive": archive,
    }
    return rows, provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--server", default="intl")
    args = parser.parse_args()
    root, output = args.release_root.resolve(), args.output_dir.resolve()
    components = json.loads((output / "components.json").read_bytes())
    recipe = json.loads((output / "recipes.json").read_bytes())
    if components["server"] != args.server or recipe["sourceId"] != components["sourceId"]:
        raise ValueError("Lane output must match the installed chart source")
    directory = "Assets/AddressableResources/Effect/Live/LaneEffect/"
    kinds = {
        "inVain": "blank_miss", "normal": "normal", "slide": "slide",
        "flick": "flick", "flickLeft": "flick_left", "flickRight": "flick_right",
        "gekisou": "excellenet",
    }
    effects = {}
    for kind, slug in kinds.items():
        rows, provenance = source_objects(root, f"{directory}effect001/lane_tap_{slug}_view.prefab")
        asset = next(row for row in rows if row.get("type") == "MonoBehaviour"
                     and row["data"].get("m_Script", {}).get("reference", {}).get("name") == "LiveLaneEffectAsset")
        data = asset["data"]

        def referenced(pointer):
            if pointer["m_FileID"] != 0:
                raise ValueError("Expected a local lane source reference")
            return next(row for row in rows if str(row.get("pathId")) == str(pointer["m_PathID"]))

        particle = referenced(data["_setupWidthParticleSystem"])
        parent = referenced(data["_parentParticleSystem"])
        renderer = next(row for row in rows if row.get("type") == "ParticleSystemRenderer"
                        and row["data"]["m_GameObject"] == particle["data"]["m_GameObject"])
        # Keep the transform chain so the producer consumes the authored plane.
        transform = next(row for row in rows if row.get("type") == "Transform"
                         and row["data"]["m_GameObject"] == particle["data"]["m_GameObject"])
        chain = []
        while True:
            chain.append(transform)
            father = transform["data"]["m_Father"]
            if str(father["m_PathID"]) == "0":
                break
            transform = referenced(father)
        effects[kind] = {
            "source": provenance,
            "particleSystem": particle,
            "parentSystem": parent,
            "renderer": renderer,
            "particleTransform": f"{chain[0]['serializedFile']}:{chain[0]['pathId']}",
            "transforms": {
                f"{node['serializedFile']}:{node['pathId']}": {
                    "sha256": digest(json.dumps(node, sort_keys=True, separators=(",", ":")).encode()),
                    "normalization": "pptr-decimal64-v1",
                    "record": normalize(node),
                } for node in reversed(chain)
            },
        }
    material_path = directory + "Common/lane_blankmiss.mat"
    material_rows, material_source = source_objects(root, material_path)
    material = next(row for row in material_rows if row.get("type") == "Material")
    if material["data"]["m_Shader"]["reference"]["name"] != "UI/Additive":
        raise ValueError("Unexpected source lane material")
    texture_path = directory + "Common/lane_effect_white.png"
    texture_metadata = root / "metadata/sources" / (texture_path + ".json")
    texture_info = json.loads(texture_metadata.read_bytes())
    texture_output = next(row for row in texture_info["outputs"] if row["role"] == "source" and row["type"] == "Texture2D")
    main_texture = next(row[1]["m_Texture"] for row in material["data"]["m_SavedProperties"]["m_TexEnvs"] if row[0] == "_MainTex")
    if str(main_texture["m_PathID"]) != str(texture_output["objectId"]):
        raise ValueError("Lane material texture pointer mismatch")
    material_metadata = json.loads((root / "metadata/sources" / (material_path + ".json")).read_bytes())
    texture_references = [row for row in material_metadata["preloadObjectReferences"]
                          if str(row["pathId"]) == str(main_texture["m_PathID"])]
    if (len(texture_references) != 1 or
            texture_references[0]["serializedFile"] != texture_output["serializedFile"]):
        raise ValueError("Lane material texture serialized-file mismatch")
    local_texture = main_texture["m_FileID"] == 0
    if local_texture != (material["serializedFile"] == texture_output["serializedFile"]):
        raise ValueError("Lane material texture reference locality mismatch")
    texture = root / "assets" / texture_path
    texture_bytes = texture.read_bytes()
    if digest(texture_bytes) != texture_output["sha256"]:
        raise ValueError("Lane texture export hash mismatch")
    (output / "textures").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(texture, output / "textures/laneEffect.png")
    geometry = recipe["geometry"]
    result = {
        "schema": "our-notes-lane-feedback-source-v1",
        "server": args.server,
        "sourceId": components["sourceId"],
        "releaseId": root.name,
        "chartLaneCount": geometry["chartLaneCount"],
        "laneWidth": geometry["laneWidth"],
        "judgementRootZ": geometry["judgementRootZ"],
        "material": {"source": material_source, "record": material},
        "texture": {"source": texture_path, "filename": "textures/laneEffect.png", "sha256": digest(texture_bytes),
                    "serializedFile": texture_output["serializedFile"], "pathId": texture_output["objectId"],
                    "metadataSha256": digest(texture_metadata.read_bytes())},
        "effects": effects,
    }
    (output / "lane-feedback.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(json.dumps({"effects": len(effects), "laneCount": result["chartLaneCount"], "textureSha256": digest(texture_bytes)}))


if __name__ == "__main__":
    main()
