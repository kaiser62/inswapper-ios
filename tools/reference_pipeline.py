"""End-to-end reference swap, run with onnxruntime and with the Core ML models, and compared.
Writes golden tensors for Phase 1's Swift code. Local only. Inputs/outputs live in tools/models/test/ (gitignored):
no face images or face-derived data may ever be committed to the public repo.

Usage: python reference_pipeline.py SOURCE.jpg TARGET.jpg
"""
import sys
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort
import coremltools as ct
from PIL import Image

ROOT = Path(__file__).parent / "models"
TEST = ROOT / "test"
RAW = ROOT / "raw"
PK = ROOT / "mlpackages"

ARCFACE_DST = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                        [41.5493, 92.3655], [70.7299, 92.2041]], np.float32)


def similarity(src, dst):
    """Least-squares similarity transform (as skimage SimilarityTransform.estimate) -> 2x3."""
    M, _ = cv2.estimateAffinePartial2D(src, dst, method=cv2.LMEDS)
    # estimateAffinePartial2D is similarity (4 DOF); LMEDS with 5 points is stable
    return M


def align(img, kps, size):
    dst = ARCFACE_DST.copy()
    if size == 128:
        dst[:, 0] += 8.0  # insightface estimate_norm: ratio 1.0, diff_x 8 for 128
    elif size != 112:
        raise ValueError(size)
    M = similarity(kps.astype(np.float32), dst)
    return cv2.warpAffine(img, M, (size, size), borderValue=0.0), M


# ---- SCRFD decode (insightface v0.7) ----
def nms(dets, thr=0.4):
    x1, y1, x2, y2, s = dets.T
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = s.argsort()[::-1]
    keep = []
    while order.size:
        i = order[0]; keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]]); yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]]); yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0, xx2 - xx1 + 1) * np.maximum(0, yy2 - yy1 + 1)
        iou = inter / (areas[i] + areas[order[1:]] - inter)
        order = order[1:][iou <= thr]
    return keep


def decode(outs, det_scale, thresh=0.5, size=640):
    scores_l, boxes_l, kps_l = [], [], []
    for idx, stride in enumerate([8, 16, 32]):
        scores = np.asarray(outs[idx], np.float32).reshape(-1)
        bbox = np.asarray(outs[idx + 3], np.float32).reshape(-1, 4) * stride
        kps = np.asarray(outs[idx + 6], np.float32).reshape(-1, 10) * stride
        h = w = size // stride
        ac = np.stack(np.mgrid[:h, :w][::-1], axis=-1).astype(np.float32)
        ac = (ac * stride).reshape(-1, 2)
        ac = np.stack([ac] * 2, axis=1).reshape(-1, 2)
        pos = np.where(scores >= thresh)[0]
        b = np.stack([ac[:, 0] - bbox[:, 0], ac[:, 1] - bbox[:, 1], ac[:, 0] + bbox[:, 2], ac[:, 1] + bbox[:, 3]], -1)
        k = np.stack([ac[:, i % 2] + kps[:, i] for i in range(10)], -1).reshape(-1, 5, 2)
        scores_l.append(scores[pos]); boxes_l.append(b[pos]); kps_l.append(k[pos])
    if not scores_l or sum(len(s) for s in scores_l) == 0:
        return None, None
    s = np.concatenate(scores_l); b = np.concatenate(boxes_l) / det_scale; k = np.concatenate(kps_l) / det_scale
    det = np.hstack([b, s[:, None]]).astype(np.float32)
    order = s.argsort()[::-1]
    det, k = det[order], k[order]
    keep = nms(det)
    return det[keep], k[keep]


def letterbox(img_bgr, size=640):
    h, w = img_bgr.shape[:2]
    r = h / w
    if r > 1:
        nh, nw = size, int(size / r)
    else:
        nw, nh = size, int(size * r)
    scale = nh / h
    canvas = np.zeros((size, size, 3), np.uint8)
    canvas[:nh, :nw] = cv2.resize(img_bgr, (nw, nh))
    return canvas, scale


class Ort:
    def __init__(self):
        mk = lambda p: ort.InferenceSession(str(p), providers=["CPUExecutionProvider"])
        self.det = mk(ROOT / "scrfd_fixed.onnx")
        self.arc = mk(ROOT / "arcface_fixed.onnx")
        self.swp = mk(ROOT / "swapper_fixed.onnx")

    def detect(self, canvas_bgr):
        blob = cv2.dnn.blobFromImage(canvas_bgr, 1 / 128.0, (640, 640), (127.5,) * 3, swapRB=True)
        return self.det.run(None, {"input.1": blob})

    def embed(self, aligned112_bgr):
        blob = cv2.dnn.blobFromImage(aligned112_bgr, 1 / 127.5, (112, 112), (127.5,) * 3, swapRB=True)
        return self.arc.run(None, {"input.1": blob})[0][0]

    def swap(self, aligned128_bgr, latent):
        blob = cv2.dnn.blobFromImage(aligned128_bgr, 1 / 255.0, (128, 128), (0, 0, 0), swapRB=True)
        return self.swp.run(None, {"target": blob, "source": latent})[0]


class CML:
    def __init__(self):
        self.det = ct.models.MLModel(str(PK / "scrfd.mlpackage"))
        self.arc = ct.models.MLModel(str(PK / "arcface.mlpackage"))
        self.swp = ct.models.MLModel(str(PK / "swapper.mlpackage"))
        self.names = ["score_8", "score_16", "score_32", "bbox_8", "bbox_16", "bbox_32", "kps_8", "kps_16", "kps_32"]

    @staticmethod
    def pil(bgr):
        return Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))

    def detect(self, canvas_bgr):
        o = self.det.predict({"image": self.pil(canvas_bgr)})
        return [np.asarray(o[n], np.float32) for n in self.names]

    def embed(self, a):
        return np.asarray(self.arc.predict({"face": self.pil(a)})["embedding"], np.float32)[0]

    def swap(self, a, latent):
        return np.asarray(self.swp.predict({"target": self.pil(a), "latent": latent})["swapped"], np.float32)


def face(img, backend):
    canvas, scale = letterbox(img)
    det, kps = decode(backend.detect(canvas), scale)
    if det is None:
        raise RuntimeError("no face found")
    i = int(np.argmax((det[:, 2] - det[:, 0]) * (det[:, 3] - det[:, 1])))
    return det[i], kps[i]


def run(backend, src, tgt, emap):
    _, skps = face(src, backend)
    a112, _ = align(src, skps, 112)
    emb = backend.embed(a112)
    emb = emb / np.linalg.norm(emb)
    latent = emb.reshape(1, -1) @ emap
    latent = (latent / np.linalg.norm(latent)).astype(np.float32)
    _, tkps = face(tgt, backend)
    a128, M = align(tgt, tkps, 128)
    pred = backend.swap(a128, latent)
    fake = np.clip(255 * pred.transpose(0, 2, 3, 1)[0], 0, 255).astype(np.uint8)[:, :, ::-1]  # RGB->BGR
    return dict(skps=skps, tkps=tkps, emb=emb, latent=latent, a128=a128, M=M, fake=fake)


def paste_back(target, fake, aimg, M):
    """insightface inswapper.get(paste_back=True) mask logic."""
    H, W = target.shape[:2]
    diff = np.abs(fake.astype(np.float32) - aimg.astype(np.float32)).mean(axis=2)
    diff[:2] = 0; diff[-2:] = 0; diff[:, :2] = 0; diff[:, -2:] = 0
    IM = cv2.invertAffineTransform(M)
    bgr = cv2.warpAffine(fake, IM, (W, H), borderValue=0.0)
    white = cv2.warpAffine(np.full(aimg.shape[:2], 255, np.float32), IM, (W, H), borderValue=0.0)
    white[white > 20] = 255
    ys, xs = np.where(white == 255)
    mh, mw = ys.max() - ys.min(), xs.max() - xs.min()
    ms = int(np.sqrt(mh * mw))
    k = max(ms // 10, 10)
    mask = cv2.erode(white, np.ones((k, k), np.uint8))
    k = max(ms // 20, 5)
    mask = cv2.GaussianBlur(mask, tuple(2 * i + 1 for i in (k, k)), 0) / 255
    mask = mask[:, :, None]
    return (mask * bgr + (1 - mask) * target.astype(np.float32)).astype(np.uint8)


def main(src_path, tgt_path):
    src = cv2.imread(src_path); tgt = cv2.imread(tgt_path)
    emap = np.fromfile(ROOT / "emap.bin", "<f4").reshape(512, 512)
    o = run(Ort(), src, tgt, emap)
    c = run(CML(), src, tgt, emap)
    print("target kps max px diff ORT vs CoreML:", float(np.abs(o["tkps"] - c["tkps"]).max()))
    print("source kps max px diff              :", float(np.abs(o["skps"] - c["skps"]).max()))
    print("ArcFace cosine ORT vs CoreML        : %.5f" % float(o["emb"] @ c["emb"]))
    print("latent cosine                       : %.5f" % float((o["latent"] @ c["latent"].T)[0, 0]))
    mse = float(np.mean((o["fake"].astype(np.float32) - c["fake"].astype(np.float32)) ** 2))
    print("128px swap PSNR ORT vs CoreML       : %.2f dB" % (10 * np.log10(255 ** 2 / max(mse, 1e-9))))
    TEST.mkdir(exist_ok=True)
    cv2.imwrite(str(TEST / "out_ort.png"), paste_back(tgt, o["fake"], o["a128"], o["M"]))
    cv2.imwrite(str(TEST / "out_coreml.png"), paste_back(tgt, c["fake"], c["a128"], c["M"]))
    np.savez(TEST / "golden.npz", **{f"ort_{k}": v for k, v in o.items()}, **{f"cml_{k}": v for k, v in c.items()})
    print("wrote out_ort.png, out_coreml.png, golden.npz in", TEST)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
