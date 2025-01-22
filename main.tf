# Creates a Azure Windows Virtual machine
resource "azurerm_windows_virtual_machine" "example" {
  name                  = var.name
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = random_password.password.result
  network_interface_ids = [azurerm_network_interface.network_interface.id]
  license_type          = var.license_type
  secure_boot_enabled = true
  source_image_id                 = var.image_id

  identity {
    type = "SystemAssigned"
  }
  os_disk {
    name                 = "${var.name}-disk"
    caching              = "ReadWrite"
    storage_account_type = var.storage_account_type
    disk_size_gb         = var.disk_size_gb
  }

  # source_image_reference {
  #   publisher = var.publisher
  #   offer     = var.offer
  #   sku       = var.sku
  #   version   = var.storage_image_version
  # }
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
  depends_on = [
    azurerm_network_interface.network_interface
  ]
}


# Creates Network Interface Card with private IP for Virtual Machine
resource "azurerm_network_interface" "network_interface" {
  name                = "${var.name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = var.ip_name
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = var.private_ip_address_allocation
  }
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}


# Creates Network Security Group NSG for Virtual Machine
resource "azurerm_network_security_group" "nsg" {
  name                = "${var.name}-nsg"
  location            = azurerm_windows_virtual_machine.example.location
  resource_group_name = azurerm_windows_virtual_machine.example.resource_group_name
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}


# Creates Network Security Group Default Rules for Virtual Machine
resource "azurerm_network_security_rule" "nsg_rules" {
  for_each                    = var.nsg_rules
  name                        = each.value.name
  priority                    = each.value.priority
  direction                   = each.value.direction
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_address_prefixes       = each.value.source_address_prefixes
  source_port_range           = each.value.source_port_range
  destination_address_prefix  = each.value.destination_address_prefix
  destination_port_range      = each.value.destination_port_range
  network_security_group_name = azurerm_network_security_group.nsg.name
  resource_group_name         = azurerm_windows_virtual_machine.example.resource_group_name
}


# Creates association (i.e) adds NSG to the NIC
resource "azurerm_network_interface_security_group_association" "security_group_association" {
  network_interface_id      = azurerm_network_interface.network_interface.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}


# Getting existing recovery_services_vault to add vm as a backup item 
data "azurerm_recovery_services_vault" "services_vault" {
  name                = var.recovery_services_vault_name
  resource_group_name = var.services_vault_resource_group_name
}
# Getting existing Backup Policy for Virtual Machine
data "azurerm_backup_policy_vm" "policy" {
  name                = "EnhancedPolicy"
  recovery_vault_name = data.azurerm_recovery_services_vault.services_vault.name
  resource_group_name = data.azurerm_recovery_services_vault.services_vault.resource_group_name
}
# Creates Backup protected Virtual Machine
resource "azurerm_backup_protected_vm" "backup_protected_vm" {
  resource_group_name = data.azurerm_recovery_services_vault.services_vault.resource_group_name
  recovery_vault_name = data.azurerm_recovery_services_vault.services_vault.name
  source_vm_id        = azurerm_windows_virtual_machine.example.id
  backup_policy_id    = data.azurerm_backup_policy_vm.policy.id


  depends_on = [
    azurerm_windows_virtual_machine.example
  ]
}


#Creates a Public IP for load balancer
resource "azurerm_public_ip" "public_ip" {
  name                = "${var.name}-public-ip"
  resource_group_name = azurerm_windows_virtual_machine.example.resource_group_name
  location            = azurerm_windows_virtual_machine.example.location
  ip_version          = var.ip_version
  sku                 = var.public_ip_sku
  sku_tier            = var.public_ip_sku_tier
  allocation_method   = var.allocation_method
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}


#Creates a Load balancer
resource "azurerm_lb" "lb" {
  name                = "${var.name}-lb"
  resource_group_name = azurerm_windows_virtual_machine.example.resource_group_name
  location            = azurerm_windows_virtual_machine.example.location
  sku                 = var.lb_sku
  sku_tier            = var.lb_sku_tier
  frontend_ip_configuration {
    name                 = "${var.name}-pubIP"
    public_ip_address_id = azurerm_public_ip.public_ip.id
  }
  depends_on = [
    azurerm_windows_virtual_machine.example
  ]
  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}


# Creates Backenf address pool for LB
resource "azurerm_lb_backend_address_pool" "backend_pool" {
  name            = "${var.name}-backend_pool"
  loadbalancer_id = azurerm_lb.lb.id
  depends_on = [
    azurerm_lb.lb
  ]
}


# Creates association between LB and vm 
resource "azurerm_network_interface_backend_address_pool_association" "backend_association" {
  network_interface_id    = azurerm_network_interface.network_interface.id
  ip_configuration_name   = var.ip_name
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend_pool.id
  depends_on = [
    azurerm_network_interface.network_interface,
    azurerm_lb_backend_address_pool.backend_pool
  ]
}


# Creates a load balancer probe
resource "azurerm_lb_probe" "lb_probe" {
  loadbalancer_id = azurerm_lb.lb.id
  name            = "https"
  port            = var.probe_ports

}


# Creates a Load balancer rule with deafult rules
resource "azurerm_lb_rule" "lb_rule" {
  loadbalancer_id                = azurerm_lb.lb.id
  name                           = "htpps"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "${var.name}-pubIP"
  probe_id                       = azurerm_lb_probe.lb_probe.id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
}


# # Extention for startup ELK script
# resource "azurerm_virtual_machine_extension" "example" {
#   name                 = "${var.name}-elkscript"
#   virtual_machine_id   = azurerm_windows_virtual_machine.example.id
#   publisher            = "Microsoft.Compute"
#   type                 = "CustomScriptExtension"
#   type_handler_version = "1.10"

#   settings = <<SETTINGS
#     {
#       "fileUris": ["https://sharedsaelk.blob.core.windows.net/elk-startup-script/elkscriptwindows.ps1"],
#       "commandToExecute": "powershell -ExecutionPolicy Bypass -File elkscriptwindows.ps1" 
#     }
# SETTINGS
# }
resource "azurerm_virtual_machine_extension" "example" {
  name                 = "${var.name}-s1agent"
  virtual_machine_id   = azurerm_windows_virtual_machine.example.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = <<SETTINGS
    {
      "fileUris": ["https://sharedsaelk.blob.core.windows.net/s1-data/s1-agent.ps1"],
      "commandToExecute": "powershell -ExecutionPolicy Bypass -File s1-agent.ps1" 
    }
SETTINGS
}

#Getting existing Keyvault name to store credentials as secrets
data "azurerm_key_vault" "key_vault" {
  name                = var.keyvault_name
  resource_group_name = var.resource_group_name
}

# Creates a random string password for vm default user
resource "random_password" "password" {
  length      = 12
  lower       = true
  min_lower   = 6
  min_numeric = 2
  min_special = 2
  min_upper   = 2
  numeric     = true
  special     = true
  upper       = true

}
# Creates a secret to store DB credentials 
resource "azurerm_key_vault_secret" "vm_password" {
  name         = "${var.name}-vmpwd"
  value        = random_password.password.result
  key_vault_id = data.azurerm_key_vault.key_vault.id

}
  