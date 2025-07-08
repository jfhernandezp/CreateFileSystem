#!/bin/bash

# Verificar permisos de root
if [[ $EUID -ne 0 ]]; then
    echo "Este script debe ejecutarse como root."
    exit 1
fi

echo "📦 Detectando discos antes del escaneo..."
DISCOS_ANTES=$(lsblk -dn -o NAME | sort)

# Escanear buses SCSI
echo "📡 Escaneando controladoras SCSI..."
for HBA in /sys/class/scsi_host/host*; do
    echo "- - -" > "$HBA/scan"
done

sleep 3

echo "📦 Detectando discos después del escaneo..."
DISCOS_DESPUES=$(lsblk -dn -o NAME | sort)

# Comparar y encontrar nuevos
DISCOS_NUEVOS=$(comm -13 <(echo "$DISCOS_ANTES") <(echo "$DISCOS_DESPUES"))

# Detectar discos sin particionar
DISCOS_DISPONIBLES=()
for disk in $DISCOS_DESPUES; do
    if [ ! -e "/dev/${disk}1" ] && ! mount | grep -q "/dev/${disk}"; then
        PARTS=$(lsblk -dn -o TYPE /dev/$disk | grep -v disk)
        if [[ -z "$PARTS" ]]; then
            DISCOS_DISPONIBLES+=("$disk")
        fi
    fi
done

if [[ ${#DISCOS_DISPONIBLES[@]} -eq 0 ]]; then
    echo "❌ No hay discos nuevos disponibles para formatear."
    exit 0
fi

echo "✅ Discos disponibles detectados:"
for i in "${!DISCOS_DISPONIBLES[@]}"; do
    echo "$((i+1)). /dev/${DISCOS_DISPONIBLES[$i]}"
done

read -p "Selecciona el número del disco a utilizar: " OPCION
DISCO_SELECCIONADO="${DISCOS_DISPONIBLES[$((OPCION-1))]}"
DISCO_PATH="/dev/$DISCO_SELECCIONADO"

if [ ! -b "$DISCO_PATH" ]; then
    echo "❌ Disco no válido."
    exit 1
fi

read -p "¿Deseas crear un nuevo volumen con LVM en $DISCO_PATH? (s/n): " CONFIRMAR
[[ "$CONFIRMAR" =~ ^[Ss]$ ]] || exit 0

# Crear partición GPT para LVM
echo "🧱 Creando partición en $DISCO_PATH..."
parted -s "$DISCO_PATH" mklabel gpt mkpart primary 0% 100% set 1 lvm on
PARTICION="${DISCO_PATH}1"

sleep 2
udevadm settle

# Crear PV y VG
pvcreate "$PARTICION"
read -p "Nombre del Volume Group (VG): " VG
vgcreate "$VG" "$PARTICION"

# Crear LV
read -p "Nombre del Logical Volume (LV): " LV
read -p "Tamaño del LV (ej. 10G): " TAMANO
lvcreate -L "$TAMANO" -n "$LV" "$VG"

# Formato de filesystem
echo "Selecciona el tipo de sistema de archivos:"
select FS in ext2 ext3 ext4 xfs; do
    case "$FS" in
        ext2|ext3|ext4|xfs) break ;;
        *) echo "❌ Opción inválida." ;;
    esac
done

mkfs.$FS /dev/$VG/$LV

# Punto de montaje
read -p "Ruta donde se montará el volumen (ej. /mnt/datos): " MOUNT
mkdir -p "$MOUNT"

# Obtener UUID y montar
UUID=$(blkid -s UUID -o value /dev/$VG/$LV)
echo "UUID=$UUID $MOUNT $FS defaults 0 0" >> /etc/fstab
mount UUID="$UUID" "$MOUNT"

echo "✅ Volumen creado, montado en $MOUNT y añadido a /etc/fstab."
