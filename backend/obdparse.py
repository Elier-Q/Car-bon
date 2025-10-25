def parse_obd_response(response: str):
    """
    Parses standard OBD-II responses.
    """
    try:
        parts = response.split()
        if len(parts) < 3:
            return None

        mode_pid_prefix = parts[0].upper()

        if mode_pid_prefix.startswith("41"):
            pid = parts[1].upper()
            if pid == "0C":
                A, B = int(parts[2], 16), int(parts[3], 16)
                rpm = ((A * 256) + B) / 4
                return {"pid": "010C", "label": "Engine RPM", "value": rpm, "unit": "rpm"}

            elif pid == "0D":
                A = int(parts[2], 16)
                return {"pid": "010D", "label": "Vehicle Speed", "value": A, "unit": "km/h"}

            elif pid == "10":
                A, B = int(parts[2], 16), int(parts[3], 16)
                maf = ((A * 256) + B) / 100
                return {"pid": "0110", "label": "Mass Air Flow", "value": maf, "unit": "g/s"}

            elif pid == "2F":
                A = int(parts[2], 16)
                fuel = (A * 100) / 255
                return {"pid": "012F", "label": "Fuel Level", "value": fuel, "unit": "%"}

        elif mode_pid_prefix.startswith("49"):
            pid = parts[1].upper()
            if pid == "02":
                vin_bytes = [
                    chr(int(b, 16)) for b in parts[3:] if len(b) == 2 and b.isalnum()
                ]
                return {"pid": "0902", "label": "VIN", "value": "".join(vin_bytes)}

        return None

    except Exception:
        return None
