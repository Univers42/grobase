# Grobase — thin orchestrator. Every variable + target lives in
# orchestrators/makes/*.mk, loaded in numeric order (00-config first).
# Run `make help` for the menu.

include $(sort $(wildcard orchestrators/makes/*.mk))
