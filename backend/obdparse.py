def parse_obd_response(response: str):
    """
    Parses standard OBD-II responses (e.g., "41 10 3A F8").
    Organized by MODE → PID for clarity and expansion.
    """
    try:
        parts = response.split()
        if len(parts) < 3:
            return None

        mode = parts[0].upper()
        pid = parts[1].upper()

        # --------------------------
        # MODE 01 — Current Data
        # --------------------------
        if mode == "41":
            if pid == "0C":  # Engine RPM
                A, B = int(parts[2], 16), int(parts[3], 16)
                rpm = ((A * 256) + B) / 4
                return {
                    "pid": "010C",
                    "label": "Engine RPM",
                    "value": rpm,
                    "unit": "rpm"
                }

            elif pid == "0D":  # Vehicle Speed
                A = int(parts[2], 16)
                return {
                    "pid": "010D",
                    "label": "Vehicle Speed",
                    "value": A,
                    "unit": "km/h"
                }

            elif pid == "10":  # Mass Air Flow (MAF)
                A, B = int(parts[2], 16), int(parts[3], 16)
                maf = ((A * 256) + B) / 100.0
                return {
                    "pid": "0110",
                    "label": "Mass Air Flow",
                    "value": maf,
                    "unit": "g/s"
                }

            elif pid == "2F":  # Fuel Level
                A = int(parts[2], 16)
                fuel = (A * 100) / 255
                return {
                    "pid": "012F",
                    "label": "Fuel Level",
                    "value": fuel,
                    "unit": "%"
                }

            else:
                # Unknown PID in Mode 01
                return {
                    "pid": f"01{pid}",
                    "label": f"Unknown PID {pid}",
                    "value": None,
                    "unit": ""
                }

        # --------------------------
        # MODE 09 — Vehicle Info
        # --------------------------
        elif mode == "49":
            if pid == "02":  # Vehicle Identification Number (VIN)
                vin_bytes = [
                    chr(int(b, 16)) for b in parts[3:]
                    if len(b) == 2 and b.isalnum()
                ]
                return {
                    "pid": "0902",
                    "label": "VIN",
                    "value": "".join(vin_bytes),
                    "unit": ""
                }

            else:
                # Unknown PID in Mode 09
                return {
                    "pid": f"09{pid}",
                    "label": f"Unknown Mode 09 PID {pid}",
                    "value": None,
                    "unit": ""
                }

        # --------------------------
        # OTHER MODES — Not Implemented
        # --------------------------
        else:
            return {
                "pid": f"{mode}{pid}",
                "label": f"Unsupported Mode {mode}",
                "value": None,
                "unit": ""
            }

    except Exception as e:
        print(f"[obdparse] Error parsing {response}: {e}")
        return None
