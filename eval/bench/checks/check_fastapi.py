from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_items_roundtrip():
    a = client.post("/items", json={"name": "pen", "price": 1.5})
    b = client.post("/items", json={"name": "ink", "price": 3})
    assert a.status_code == 201 and b.status_code == 201
    ja, jb = a.json(), b.json()
    assert isinstance(ja["id"], int) and jb["id"] == ja["id"] + 1
    assert ja["name"] == "pen" and float(ja["price"]) == 1.5
    g = client.get("/items/%d" % jb["id"])
    assert g.status_code == 200
    assert g.json()["name"] == "ink" and float(g.json()["price"]) == 3.0


def test_missing_and_invalid():
    assert client.get("/items/987654").status_code == 404
    assert client.post("/items", json={"name": "x"}).status_code == 422
    assert client.post("/items", json={"name": "x", "price": "abc"}).status_code == 422
