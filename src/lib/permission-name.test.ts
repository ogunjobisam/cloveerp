import { describe, expect, test } from "bun:test";

import { humanisePermission, permissionName, permissionNameKey } from "./permission-name";

describe("a permission's name", () => {
  test("is held under the key erp_ref.permission.name_key names", () => {
    expect(permissionNameKey("administration.configure")).toBe(
      "permission.administration.configure",
    );
  });

  test("is the dictionary's, where it has one — renamed or translated", () => {
    const resources = {
      "permission.administration.configure": "Change configuration",
      "permission.sales.despatch": "Dispatch orders",
    };
    expect(permissionName("administration.configure", resources)).toBe("Change configuration");
    expect(permissionName("sales.despatch", resources)).toBe("Dispatch orders");
  });

  test("is the code in words while the dictionary has nothing for it", () => {
    expect(permissionName("administration.configure", {})).toBe("Administration: configure");
    expect(
      permissionName("administration.configure", { "permission.administration.configure": "  " }),
    ).toBe("Administration: configure");
  });
});

describe("a permission code in words", () => {
  test("names the module the way the navigation does", () => {
    expect(humanisePermission("inventory.write_off")).toBe("Stock: write off");
    expect(humanisePermission("master_data.approve")).toBe("Common data: approve");
    expect(humanisePermission("procurement.order")).toBe("Purchasing: order");
  });

  test("capitalises a module the navigation does not rename", () => {
    expect(humanisePermission("sales.credit_release")).toBe("Sales: credit release");
    expect(humanisePermission("document.template_manage")).toBe("Document: template manage");
  });

  test("reads anything that is not module.action as it stands, and is never empty", () => {
    expect(humanisePermission("configure")).toBe("Configure");
    expect(humanisePermission("administration.")).toBe("Administration.");
    expect(humanisePermission(" .roles")).toBe(".roles");
    for (const code of ["a.b", "x_y.z_w", "odd"]) {
      expect(humanisePermission(code)).not.toBe("");
    }
  });
});
