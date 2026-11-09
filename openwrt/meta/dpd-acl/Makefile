include $(TOPDIR)/rules.mk

PKG_NAME:=dpd-acl
PKG_VERSION:=0.1.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=kwrum1

include $(INCLUDE_DIR)/package.mk

define Package/dpd-acl
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=DPD
  TITLE:=DPD ACL plugin (router-acl)
  DEPENDS:=+router-acl
  PKGARCH:=all
endef

define Package/dpd-acl/description
  Meta package for the DPD plugin name. The implementation stays in router-acl so
  existing UCI/LuCI remains compatible.
endef

define Build/Compile
endef

define Package/dpd-acl/install
	$(INSTALL_DIR) $(1)/usr/share/dpd
	$(INSTALL_DIR) $(1)/usr/lib/dpd
	$(INSTALL_BIN) ../files/keep-settings.sh $(1)/usr/lib/dpd/keep-settings.sh
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/uci-defaults/90-dpd-acl-keep-settings $(1)/etc/uci-defaults/90-dpd-acl-keep-settings
endef

$(eval $(call BuildPackage,dpd-acl))