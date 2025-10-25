from fastapi import FastAPI, Request
from datetime import datetime

app = FastAPI()

@app.post("/obd-data")
async def receive_obd_data(request: Request):
    """
    Receives OBD2 responses from the iOS BLE bridge app.
    Each payload looks like: {"response": "41 0C 1A F8"}
    """
    data = await request.json()
    response = data.get("response", "").strip()

    print(f"[{datetime.now().isoformat()}] Received: {response}")

    # (Optional) Parse common OBD-II PIDs here
    parsed = parse_obd_response(response)

    # Return parsed info (for debugging or app confirmation)
    return {"ok": True, "raw": response, "parsed": parsed}


def parse_obd_response(response: str):
    """
    Basic parser for a few standard OBD-II responses.
    """
    try:
        parts = response.split()
        if len(parts) < 3 or not parts[0].startswith("41"):
            return None

        pid = parts[1]
        if pid == "0C":  # RPM
            A, B = int(parts[2], 16), int(parts[3], 16)
            rpm = ((A * 256) + B) / 4
            return {"pid": "010C", "label": "Engine RPM", "value": rpm, "unit": "rpm"}

        elif pid == "0D":  # Speed
            A = int(parts[2], 16)
            return {"pid": "010D", "label": "Vehicle Speed", "value": A, "unit": "km/h"}

        else:
            return {"pid": pid, "raw": response}
    except Exception:
        return None


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
