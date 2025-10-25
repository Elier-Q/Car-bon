# obd_ble_reader.py
import asyncio
from bleak import BleakClient, BleakScanner

OBD_SERVICE_UUID = "0000fff0-0000-1000-8000-00805f9b34fb"  # common serial service
OBD_WRITE_UUID = "0000fff2-0000-1000-8000-00805f9b34fb"
OBD_NOTIFY_UUID = "0000fff1-0000-1000-8000-00805f9b34fb"

async def main():
    print("Scanning for Veepak OBD-II devices...")
    devices = await BleakScanner.discover()
    veepak = next((d for d in devices if "VEEPEAK" in d.name.upper()), None)
    if not veepak:
        print("No Veepak found.")
        return

    print(f"Connecting to {veepak.name} ({veepak.address})...")
    async with BleakClient(veepak.address) as client:
        print("Connected!")

        # Set up notification handler
        def handle_data(_, data):
            print("Response:", data.decode(errors="ignore").strip())

        await client.start_notify(OBD_NOTIFY_UUID, handle_data)

        # Send commands (OBD-II requests)
        for cmd in ["010D", "0110"]:
            msg = (cmd + "\r").encode()
            print(f"→ {cmd}")
            await client.write_gatt_char(OBD_WRITE_UUID, msg)
            await asyncio.sleep(2)

        await client.stop_notify(OBD_NOTIFY_UUID)

asyncio.run(main())
