# 07 · Máquinas virtuales

## 1. Conceptos
Una **máquina virtual** es un computador completo emulado por software: tiene su propio kernel,
sistema operativo, CPU virtual, memoria, discos y NIC. La crea y aísla un **hipervisor**.

| Tipo de hipervisor | Dónde corre | Ejemplos |
|---|---|---|
| **Tipo 1 (bare metal)** | Directamente sobre el hardware | Hyper-V (base de Azure), VMware ESXi, KVM, Xen |
| **Tipo 2 (hosted)** | Sobre un SO anfitrión | VirtualBox, VMware Workstation |

### VM vs. contenedor
| | Máquina virtual | Contenedor |
|---|---|---|
| Aísla | Hardware virtual + kernel propio | Procesos (namespaces y cgroups), kernel compartido |
| Tamaño | GB | MB |
| Arranque | 30 s – minutos | Milisegundos – segundos |
| Aislamiento de seguridad | Fuerte | Menor (se refuerza con seccomp, no-root, etc.) |
| Uso típico | SO completo, software legado, cargas con estado | Microservicios, escalado rápido |

En la nube **los contenedores corren sobre VMs**: los nodos de AKS son VMs de un VMSS, y Container
Apps usa VMs administradas que no se ven.

### Familias de VM en Azure
| Familia | Uso | Ejemplo |
|---|---|---|
| **B (burstable)** | Cargas con picos ocasionales: acumulan créditos de CPU en reposo | B1s, B2s, B2ats v2 (TeamForMe) |
| D | Propósito general | D2s v5 |
| E | Memoria intensiva | E4s v5 |
| F | CPU intensiva | F4s v2 |
| N | GPU | NC, ND |
| L | Almacenamiento/IO | L8s v3 |

### Modelos de compra
| Modelo | Descuento | Cuándo |
|---|---|---|
| Pago por uso | — | Desarrollo, cargas variables |
| Reservas (1–3 años) | hasta ~72 % | Cargas estables 24/7 |
| **Spot** | hasta ~90 % | Trabajos interrumpibles (batch, CI, nodos de AKS secundarios) |
| Savings plan | hasta ~65 % | Compromiso de gasto por hora |
| **Free tier de Azure for Students** | 100 % | B1s / B2ats v2 / B2pts v2 750 h/mes |

### Ciclo de vida y costo
| Estado | ¿Cobra cómputo? | ¿Cobra disco? |
|---|---|---|
| Running | Sí | Sí |
| Stopped (desde el SO) | **Sí** (el hardware sigue reservado) | Sí |
| **Deallocated** (`az vm deallocate`) | No | Sí |
| Eliminada | No | No (si se borran los discos) |

## 2. Implementación en TeamForMe

### 2.1 VM única: "lift & shift" del sistema completo (IaaS)
`infra/modules/vm.bicep` crea:

| Recurso | Configuración |
|---|---|
| VNet + subred | `10.10.0.0/16` |
| NSG (firewall) | SSH 22 y Grafana/Prometheus solo desde **tu IP**; 8080 (gateway) público |
| IP pública estática | Standard SKU + nombre DNS |
| VM | Ubuntu 24.04 LTS, **Standard_B1s**, autenticación **solo por clave SSH** |
| Disco | P6 64 GiB Premium SSD (dentro de la oferta gratuita) |
| cloud-init | Instala Docker y crea 2 GB de swap (la B1s tiene 1 GiB de RAM) |
| Identidad | La identidad administrada `id-teamforme` (puede leer Key Vault y hacer pull de ACR) |

Despliegue y uso:
```powershell
./scripts/azure/deploy.ps1 -WithVm -SshPublicKeyPath $HOME/.ssh/id_ed25519.pub
```
```bash
scp -r docker-compose.yml .env.example microservices gateway observability TeamForMeFrontend azureuser@<vmFqdn>:~/teamforme/
```
```bash
ssh azureuser@<vmFqdn>
```
Dentro de la VM:
```bash
cd ~/teamforme && cp .env.example .env && docker compose up -d --build
```
La aplicación queda en `http://<vmFqdn>:8080`. Para aligerar la VM se puede omitir el frontend:
`docker compose up -d --build gateway ms-events ms-teams ms-applications ms-users ms-notifications prometheus grafana`.

Para que la VM use Key Vault en lugar de `.env`, basta con completar en `.env`
`KEYVAULT_URI=https://<kv>.vault.azure.net/` y `AZURE_CLIENT_ID=<identityClientId>` (ambos son
salidas de `deploy.ps1`). La identidad administrada de la VM se autentica sola mediante el
endpoint IMDS, sin guardar ninguna credencial en la máquina.

**Escalado vertical de la VM:**
```bash
az vm resize -g rg-teamforme -n vm-teamforme --size Standard_B2s
```
Implica un reinicio: es la principal limitación del escalado vertical.

### 2.2 VMSS: escalado horizontal de VMs
`infra/modules/vmss.bicep`: conjunto de VMs idénticas (Ubuntu + nginx que responde con su
hostname) con **Autoscale de Azure Monitor** (1–3 instancias, CPU > 70 % ⇒ +1, < 30 % ⇒ −1).
Es el mismo mecanismo que usan los *node pools* de AKS por debajo.

```powershell
./scripts/azure/deploy.ps1 -WithVmss
```
```bash
az vmss list-instances -g rg-teamforme -n vmss-teamforme -o table
```

### 2.3 Comparación de las tres formas de correr TeamForMe en Azure
| | VM (IaaS) | AKS (CaaS) | Container Apps (PaaS serverless) |
|---|---|---|---|
| Tú gestionas | SO, Docker, parches, firewall | Manifiestos, nodos (tamaño), upgrades | Solo la app |
| Escalado | Vertical manual / VMSS | HPA + Cluster Autoscaler | KEDA automático, incluye 0 |
| Costo mínimo | 0 con free tier (B1s) | 1 nodo B2s (~30 USD/mes) | ~0 dentro del grant |
| Tiempo hasta producción | Medio | Alto | **Bajo** |
| Alta disponibilidad | No (1 VM) | Sí | Sí |

## 3. Buenas prácticas aplicadas
- Solo SSH con clave pública (`disablePasswordAuthentication: true`).
- NSG con origen restringido a la IP del administrador.
- Identidad administrada en lugar de credenciales en archivos.
- `deallocate` cuando no se usa (`scripts/azure/costs.ps1 -Action Pause`).
- Imagen base LTS y `package_update` en cloud-init.
