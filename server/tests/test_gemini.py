from helpert_server import ia


def test_gemini_pide_el_esquema_y_usa_su_url(monkeypatch):
    visto = {}

    def post(url, cuerpo, cab, timeout):
        visto.update(url=url, cuerpo=cuerpo, cab=cab)
        return {"choices": [{"message": {"content": "{}"}}], "usage": {"prompt_tokens": 3, "completion_tokens": 1}}

    monkeypatch.setattr(ia, "_post", post)
    monkeypatch.setenv("HELPERT_IA_G", "k")
    ia.PROVEEDORES["gemini"]({"proveedor": "gemini", "modelo": "gemini-x", "clave_env": "HELPERT_IA_G"}, [])
    assert visto["url"] == ia.GEMINI + "/chat/completions" and visto["cab"]["Authorization"] == "Bearer k"
    assert visto["cuerpo"]["response_format"]["json_schema"]["schema"]["required"][0] == "accion"
    assert visto["cuerpo"]["reasoning_effort"] == "low"
    ia.PROVEEDORES["gemini"]({"proveedor": "gemini", "modelo": "gemini-x", "clave_env": "HELPERT_IA_G", "libre": True}, [])
    assert "response_format" not in visto["cuerpo"]  # describir una captura: texto libre
    ia.PROVEEDORES["openai-compatible"]({"proveedor": "openai-compatible", "modelo": "m", "clave_env": "HELPERT_IA_G"}, [])
    assert "response_format" not in visto["cuerpo"] and "reasoning_effort" not in visto["cuerpo"]
