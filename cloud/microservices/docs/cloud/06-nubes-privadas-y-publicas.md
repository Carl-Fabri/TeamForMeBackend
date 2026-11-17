# 06 · Gerenciamiento de nubes privadas y públicas

## 1. Modelos de despliegue (NIST)
| Modelo | Infraestructura | Quién opera | Ventajas | Desventajas |
|---|---|---|---|---|
| **Pública** | Compartida, del proveedor (Azure, AWS, GCP) | Proveedor (hardware) + cliente (cargas) | Sin inversión inicial, elasticidad casi infinita, servicios administrados | Dependencia del proveedor, costo variable, soberanía de datos |
| **Privada** | Dedicada a una organización (on-premises o hosting) | La organización | Control total, cumplimiento, latencia local | CAPEX alto, capacidad fija, equipo de operación |
| **Híbrida** | Privada + pública conectadas | Ambos | Ráfagas a la pública (*cloud bursting*), datos sensibles en casa | Complejidad de red, identidad y gestión |
| **Comunitaria** | Compartida por organizaciones con requisitos comunes | Consorcio | Costos compartidos, cumplimiento sectorial | Gobernanza compleja |
| **Multicloud** | Varias nubes públicas | Cliente | Evita *lock-in*, usa lo mejor de cada una | Más superficie de gestión |

### Modelos de servicio y responsabilidad compartida
| Capa | On-premises | IaaS (VM) | PaaS (Container Apps) | SaaS |
|---|---|---|---|---|
| Aplicación y datos | Cliente | Cliente | Cliente | Proveedor |
| Runtime / contenedores | Cliente | Cliente | **Proveedor** | Proveedor |
| Sistema operativo | Cliente | Cliente | Proveedor | Proveedor |
| Virtualización / hardware / red física | Cliente | Proveedor | Proveedor | Proveedor |

En TeamForMe conviven los tres modelos: **IaaS** (`vm.bicep`, `vmss.bicep`), **CaaS/PaaS**
(AKS, Container Apps) y **SaaS** (Key Vault, Log Analytics, ACR).

## 2. Gestión de una nube pública: cómo se hace en este proyecto (Azure)

| Disciplina | Herramienta Azure | Aplicación en TeamForMe |
|---|---|---|
| **Organización** | Management groups → suscripciones → grupos de recursos | Todo en `rg-teamforme`: se crea y destruye como unidad |
| **Infraestructura como código** | Bicep / ARM | `infra/main.bicep` + módulos, idempotente |
| **Identidad y acceso** | Microsoft Entra ID + RBAC | Identidad administrada, roles mínimos (Secrets User, AcrPull) |
| **Secretos** | Key Vault | `Internal--ApiKey`, `grafana-admin-password` |
| **Gobernanza** | Azure Policy, etiquetas | Etiquetas `project`, `environment`; la suscripción de estudiante trae políticas de regiones permitidas |
| **Costos (FinOps)** | Cost Management + Budgets | Presupuesto con alertas al 50/80/100 %; `costs.ps1` |
| **Monitoreo** | Azure Monitor, Log Analytics | Logs de Container Apps, métricas de plataforma |
| **Seguridad** | Microsoft Defender for Cloud | Recomendaciones gratuitas (CSPM básico) |
| **Ciclo de vida** | Deployments de ARM | `az deployment group list` = historial de cambios |

Comandos de gestión frecuentes:
```bash
az resource list -g rg-teamforme -o table
```
```bash
az consumption usage list --start-date 2026-10-01 --end-date 2026-10-31 -o table
```
```bash
az deployment group list -g rg-teamforme -o table
```

## 3. Gestión de una nube privada

### 3.1 Plataformas
| Plataforma | Tipo | Comentario |
|---|---|---|
| **OpenStack** | IaaS open source | Nova (cómputo), Neutron (red), Cinder/Swift (almacenamiento), Keystone (identidad), Heat (orquestación) |
| **VMware vSphere / VCF** | Virtualización empresarial | vCenter para la gestión, NSX para la red |
| **Proxmox VE** | KVM + LXC | Opción ligera para laboratorio |
| **Kubernetes on-premises** (k3s, RKE2, OpenShift) | Contenedores | Mismo modelo que AKS, operado por uno mismo |
| **Azure Stack HCI / Azure Local** | Híbrido | Hardware propio gestionado desde el portal de Azure |

### 3.2 Qué cambia respecto a la pública
- Hay que planificar capacidad (comprar servidores con meses de antelación): **la elasticidad está
  acotada por el hardware**.
- El equipo opera hipervisores, almacenamiento, red, parches, backups y alta disponibilidad del plano de control.
- Los equivalentes de los servicios administrados se instalan a mano: HashiCorp Vault en lugar de
  Key Vault, Harbor en lugar de ACR, Prometheus + Grafana (iguales) en lugar de Azure Monitor.

### 3.3 TeamForMe en una nube privada
El diseño es portable porque todo es contenedor + configuración externa:

| Componente | Nube pública (Azure) | Nube privada |
|---|---|---|
| Orquestador | Container Apps / AKS | k3s / OpenShift con los mismos manifiestos `k8s/` |
| Registro | ACR | Harbor |
| Secretos | Key Vault | HashiCorp Vault (+ External Secrets Operator) |
| Métricas | Prometheus/Grafana + Azure Monitor | Prometheus/Grafana (mismos archivos de `observability/`) |
| IaC | Bicep | Terraform (provider OpenStack/vSphere) + Ansible |

El overlay `k8s/ms-events/overlays/local` es, en la práctica, la versión "nube privada".

## 4. Nube híbrida y multicloud
- **Azure Arc:** proyecta servidores y clústeres Kubernetes on-premises u otras nubes en el portal
  de Azure, con las mismas políticas, GitOps (Flux) y monitoreo.
- **Conectividad:** VPN Gateway (sitio a sitio) o ExpressRoute (enlace privado dedicado).
- **Identidad unificada:** Entra ID sincronizado con el Active Directory local.
- **Cloud bursting para TeamForMe:** en la semana de un evento masivo, MS.Events corre en un
  clúster on-premises y desborda a AKS/Container Apps cuando la cola o la CPU superan un umbral.

## 5. Criterios para elegir
| Criterio | Pública | Privada |
|---|---|---|
| Demanda variable o impredecible (picos por eventos) | ✔ | |
| Presupuesto inicial bajo (estudiantes) | ✔ | |
| Datos regulados o soberanía estricta | | ✔ |
| Carga estable 24/7 a gran escala durante años | | ✔ (puede salir más barata) |
| Equipo de operación pequeño | ✔ | |

TeamForMe usa **nube pública** por su demanda en picos (eventos puntuales), el presupuesto de
estudiante y la ausencia de requisitos regulatorios especiales.
