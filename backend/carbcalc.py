def calculate_from_maf(maf_gs: float):
    """Estimate CO₂ emissions using MAF (grams/second)"""
    afr = 14.7
    fuel_density = 750
    fuel_gs = maf_gs / afr
    fuel_lph = (fuel_gs / fuel_density) * 3600
    co2_kgph = fuel_lph * 2.31
    return {"co2_kg_per_hr": co2_kgph, "fuel_lph": fuel_lph}


def calculate_from_fuel_rate(fuel_lph: float):
    """Estimate CO₂ directly from fuel rate (L/h)"""
    co2_kgph = fuel_lph * 2.31
    return {"co2_kg_per_hr": co2_kgph, "fuel_lph": fuel_lph}


def calculate_from_speed_rpm_load(
    speed_kmh: float, 
    rpm: float, 
    load_pct: float,
    displacement: float = 1.5,
    air_density: float = 1.2
):
    """
    Speed-Density method: Calculate fuel consumption from RPM, Load, and engine parameters.
    """
    AFR = 14.7
    FUEL_DENSITY = 750
    
    load_decimal = load_pct / 100.0
    
    # Calculate MAF (Mass Air Flow) in g/s
    maf_gs = (rpm * load_decimal * displacement * air_density) / 120
    
    # Calculate fuel consumption
    fuel_gs = maf_gs / AFR
    fuel_lph = (fuel_gs / FUEL_DENSITY) * 3600
    
    # Calculate CO₂
    co2_kgph = fuel_lph * 2.31
    
    return {
        "co2_kg_per_hr": round(co2_kgph, 2),
        "fuel_lph": round(fuel_lph, 2),
        "maf_g_s": round(maf_gs, 2)
    }
