export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      erp_account_determination_rules: {
        Args: { p_transaction_type?: string }
        Returns: Json
      }
      erp_accounts: { Args: { p_postable_only?: boolean }; Returns: Json }
      erp_add_document_line: {
        Args: {
          p_description?: string
          p_document_id: string
          p_item_id: string
          p_quantity: number
          p_unit_price_minor?: number
        }
        Returns: Json
      }
      erp_add_party_role: {
        Args: { p_party_id: string; p_role_kind: string }
        Returns: Json
      }
      erp_allocate_landed_cost: {
        Args: { p_landed_cost_id: string }
        Returns: number
      }
      erp_amend_batch: {
        Args: {
          p_batch_id: string
          p_field: string
          p_reason: string
          p_value: string
        }
        Returns: undefined
      }
      erp_amend_document_line: {
        Args: { p_line_id: string; p_quantity: number; p_reason: string }
        Returns: undefined
      }
      erp_apply_calculated_policy: {
        Args: { p_item_id: string; p_site_id: string }
        Returns: undefined
      }
      erp_apply_cash: {
        Args: {
          p_amount_minor: number
          p_currency: string
          p_party_id: string
          p_reference?: string
        }
        Returns: {
          applied_minor: number
          remaining_minor: number
          subledger_item_id: string
        }[]
      }
      erp_apply_change_request: {
        Args: { p_request_id: string }
        Returns: Json
      }
      erp_apply_mass_change: {
        Args: { p_mass_change_id: string }
        Returns: number
      }
      erp_approval_audit: {
        Args: { p_limit?: number; p_object_type?: string }
        Returns: Json
      }
      erp_approval_bands: {
        Args: { p_department_id?: string; p_object_type?: string }
        Returns: Json
      }
      erp_approval_delegations: {
        Args: { p_include_ended?: boolean }
        Returns: Json
      }
      erp_approval_routing_stamps: { Args: { p_limit?: number }; Returns: Json }
      erp_approve_change_set: {
        Args: { p_change_set_id: string }
        Returns: Json
      }
      erp_approve_payment_run: {
        Args: { p_proposal_id: string }
        Returns: number
      }
      erp_approver_assignments: {
        Args: { p_object_type?: string }
        Returns: Json
      }
      erp_assign_department: {
        Args: {
          p_app_user_id: string
          p_department_id: string
          p_is_primary?: boolean
          p_valid_from?: string
          p_valid_to?: string
        }
        Returns: Json
      }
      erp_assign_named_approver: {
        Args: {
          p_approver_user_id: string
          p_lower_bound_minor?: number
          p_mode?: string
          p_object_type: string
          p_reason?: string
          p_subject_id: string
          p_subject_kind: string
          p_upper_bound_minor?: number
          p_valid_from?: string
          p_valid_to?: string
        }
        Returns: Json
      }
      erp_audit_log: {
        Args: {
          p_action?: string
          p_actor?: string
          p_from?: string
          p_limit?: number
          p_object_type?: string
          p_to?: string
        }
        Returns: Json
      }
      erp_available_to_promise: {
        Args: { p_item_id: string; p_on?: string; p_site_id: string }
        Returns: Json
      }
      erp_available_transitions: {
        Args: { p_document_id: string }
        Returns: Json
      }
      erp_batch_audit: { Args: { p_batch_id: string }; Returns: Json }
      erp_batch_record: { Args: { p_works_order_id: string }; Returns: Json }
      erp_batches: { Args: { p_limit?: number }; Returns: Json }
      erp_book_operation_time: {
        Args: {
          p_completed?: number
          p_minutes: number
          p_operation_seq: number
          p_scrapped?: number
          p_works_order_id: string
        }
        Returns: undefined
      }
      erp_book_shipment: {
        Args: {
          p_carrier_code: string
          p_cost_minor?: number
          p_service_code: string
          p_shipment_id: string
        }
        Returns: undefined
      }
      erp_budget_position: { Args: { p_code: string }; Returns: Json }
      erp_calculate_policy: {
        Args: { p_item_id: string; p_site_id: string }
        Returns: Json
      }
      erp_cancel_command: {
        Args: { p_command_id: string; p_reason: string }
        Returns: undefined
      }
      erp_change_requests: { Args: { p_object_type?: string }; Returns: Json }
      erp_change_sets: { Args: never; Returns: Json }
      erp_claim_invitation: { Args: { p_token: string }; Returns: Json }
      erp_clear_kill_switch: {
        Args: {
          p_key: string
          p_kind:
            | "rule_set"
            | "rule"
            | "state_machine"
            | "approval_chain"
            | "job"
            | "command_class"
            | "integration"
            | "event_consumer"
        }
        Returns: undefined
      }
      erp_close_period: {
        Args: { p_fiscal_period_id: string }
        Returns: undefined
      }
      erp_close_quality_event: {
        Args: {
          p_corrective_action: string
          p_event_id: string
          p_preventive_action: string
          p_root_cause: string
        }
        Returns: undefined
      }
      erp_close_status: { Args: { p_fiscal_period_id: string }; Returns: Json }
      erp_close_tasks: { Args: { p_limit?: number }; Returns: Json }
      erp_close_works_order: {
        Args: { p_works_order_id: string }
        Returns: Json
      }
      erp_commit_allocation: {
        Args: {
          p_allocation_id: string
          p_batch_id?: string
          p_location_id?: string
        }
        Returns: number
      }
      erp_complete_close_task: {
        Args: { p_task_id: string; p_waiver_reason?: string }
        Returns: string
      }
      erp_complete_warehouse_task: {
        Args: { p_quantity?: number; p_task_id: string }
        Returns: Json
      }
      erp_configure_finance: {
        Args: { p_currency?: string; p_fiscal_year?: number }
        Returns: string
      }
      erp_configure_inventory: {
        Args: { p_approver_role?: string; p_method?: string }
        Returns: string
      }
      erp_configure_logistics: { Args: never; Returns: string }
      erp_configure_master_data: {
        Args: { p_approver_role?: string }
        Returns: string
      }
      erp_configure_period_close: { Args: never; Returns: string }
      erp_configure_planning: {
        Args: { p_service_level_pct?: number }
        Returns: string
      }
      erp_configure_procurement: {
        Args: { p_approval_threshold_minor?: number }
        Returns: Json
      }
      erp_configure_procurement_controls: {
        Args: { p_approver_role?: string }
        Returns: string
      }
      erp_configure_production: { Args: never; Returns: string }
      erp_configure_quality: { Args: never; Returns: string }
      erp_configure_receivables: { Args: never; Returns: string }
      erp_configure_sales: {
        Args: { p_discount_threshold_pct?: number }
        Returns: Json
      }
      erp_configure_sales_controls: {
        Args: { p_min_margin_pct?: number }
        Returns: string
      }
      erp_configure_tax: {
        Args: { p_home_country?: string; p_standard_rate?: number }
        Returns: string
      }
      erp_count_accuracy: { Args: never; Returns: Json }
      erp_count_tasks: { Args: { p_limit?: number }; Returns: Json }
      erp_create_document: {
        Args: {
          p_party_id?: string
          p_required_date?: string
          p_site_id?: string
          p_their_ref?: string
          p_type_code: string
        }
        Returns: Json
      }
      erp_create_item: {
        Args: {
          p_code: string
          p_is_batch_controlled?: boolean
          p_item_class?: string
          p_name: string
        }
        Returns: Json
      }
      erp_create_party: {
        Args: {
          p_code: string
          p_country_code?: string
          p_name: string
          p_role_kind?: string
        }
        Returns: Json
      }
      erp_create_service_principal: {
        Args: { p_display_name: string }
        Returns: Json
      }
      erp_credit_position: { Args: { p_party_id: string }; Returns: Json }
      erp_currencies: { Args: never; Returns: Json }
      erp_data_quality: { Args: { p_object_type: string }; Returns: Json }
      erp_decide_approval: {
        Args: { p_approve: boolean; p_comment?: string; p_task_id: string }
        Returns: Json
      }
      erp_delegate_approval: {
        Args: {
          p_delegate_user_id: string
          p_delegator_user_id: string
          p_kind?: string
          p_lower_bound_minor?: number
          p_object_type?: string
          p_reason?: string
          p_upper_bound_minor?: number
          p_valid_from?: string
          p_valid_to?: string
        }
        Returns: Json
      }
      erp_delivery_performance: { Args: { p_days?: number }; Returns: Json }
      erp_department_members: {
        Args: { p_department_id?: string }
        Returns: Json
      }
      erp_departments: { Args: never; Returns: Json }
      erp_determination_coverage: { Args: never; Returns: Json }
      erp_determine_account: {
        Args: {
          p_entity_id?: string
          p_item_id?: string
          p_ledger_id?: string
          p_party_id?: string
          p_reason_code?: string
          p_site_id?: string
          p_transaction_type: string
        }
        Returns: Json
      }
      erp_dimension_rules: { Args: never; Returns: Json }
      erp_dimensions: { Args: never; Returns: Json }
      erp_disposition_inspection: {
        Args: {
          p_disposition:
            | "pending"
            | "accept"
            | "accept_with_concession"
            | "rework"
            | "reject"
            | "quarantine"
            | "destroy"
          p_inspection_id: string
          p_note?: string
        }
        Returns:
          | "pending"
          | "accept"
          | "accept_with_concession"
          | "rework"
          | "reject"
          | "quarantine"
          | "destroy"
      }
      erp_document: { Args: { p_document_id: string }; Returns: Json }
      erp_document_approval_chain: {
        Args: { p_document_id: string }
        Returns: Json
      }
      erp_document_lines: {
        Args: { p_document_id?: string; p_limit?: number; p_type_code?: string }
        Returns: Json
      }
      erp_document_types: { Args: { p_base_type_code?: string }; Returns: Json }
      erp_documents: {
        Args: { p_limit?: number; p_type_code?: string }
        Returns: Json
      }
      erp_dunning_worklist: { Args: never; Returns: Json }
      erp_duplicate_candidates: {
        Args: { p_object_type: string }
        Returns: Json
      }
      erp_end_approval_delegation: {
        Args: { p_delegation_id: string; p_reason?: string }
        Returns: Json
      }
      erp_end_approver_assignment: {
        Args: { p_assignment_id: string }
        Returns: Json
      }
      erp_end_department_membership: {
        Args: { p_membership_id: string; p_valid_to?: string }
        Returns: Json
      }
      erp_entities: { Args: never; Returns: Json }
      erp_excursion_impact: {
        Args: {
          p_from: string
          p_location_id: string
          p_site_id: string
          p_to: string
        }
        Returns: Json
      }
      erp_expiry_horizon: { Args: { p_days?: number }; Returns: Json }
      erp_export_tenant: { Args: never; Returns: Json }
      erp_fiscal_periods: { Args: never; Returns: Json }
      erp_fixed_asset_register: { Args: { p_as_at?: string }; Returns: Json }
      erp_forecast_versions: { Args: { p_limit?: number }; Returns: Json }
      erp_go_live: { Args: never; Returns: Json }
      erp_grant_role: {
        Args: {
          p_app_user_id: string
          p_grant_reason?: string
          p_role_id: string
          p_valid_from?: string
          p_valid_to?: string
        }
        Returns: Json
      }
      erp_grni: { Args: never; Returns: Json }
      erp_import_batches: { Args: { p_limit?: number }; Returns: Json }
      erp_inspections: { Args: { p_limit?: number }; Returns: Json }
      erp_integration_backlog: { Args: { p_limit?: number }; Returns: Json }
      erp_integration_health: { Args: never; Returns: Json }
      erp_intercompany_position: { Args: never; Returns: Json }
      erp_invite_principal: {
        Args: { p_display_name: string; p_email: string }
        Returns: Json
      }
      erp_invoice_against: {
        Args: {
          p_invoice_id: string
          p_order_line_id: string
          p_quantity: number
          p_unit_price_minor?: number
        }
        Returns:
          | "matched"
          | "quantity_variance"
          | "price_variance"
          | "both"
          | "unmatched"
      }
      erp_invoice_from_delivery: {
        Args: { p_allow_self_invoice?: boolean; p_delivery_id: string }
        Returns: string
      }
      erp_issue_to_works_order: {
        Args: {
          p_batch_id?: string
          p_component_item_id: string
          p_location_id?: string
          p_quantity: number
          p_works_order_id: string
        }
        Returns: number
      }
      erp_item_posting_classes: { Args: { p_limit?: number }; Returns: Json }
      erp_items: { Args: { p_search?: string }; Returns: Json }
      erp_job_health: { Args: never; Returns: Json }
      erp_landed_costs: { Args: { p_limit?: number }; Returns: Json }
      erp_ledgers: { Args: never; Returns: Json }
      erp_link_documents: {
        Args: {
          p_from_document_id: string
          p_kind:
            | "fulfils"
            | "invoices"
            | "credits"
            | "converts"
            | "returns"
            | "consumes"
            | "corrects"
            | "consolidates"
          p_quantity?: number
          p_to_document_id: string
        }
        Returns: string
      }
      erp_load_import: { Args: { p_batch_id: string }; Returns: number }
      erp_locations: { Args: { p_site_id?: string }; Returns: Json }
      erp_log_recall_action: {
        Args: {
          p_action_kind: string
          p_evidence_ref?: string
          p_impact_id?: number
          p_note?: string
          p_party_id?: string
          p_quantity_recovered?: number
          p_recall_id: string
        }
        Returns: number
      }
      erp_match_workbench: { Args: never; Returns: Json }
      erp_merge_batches: {
        Args: {
          p_reason: string
          p_source_batch_id: string
          p_target_batch_id: string
        }
        Returns: Json
      }
      erp_merge_master_record: {
        Args: {
          p_duplicate_id: string
          p_object_type: string
          p_reason: string
          p_survivor_id: string
        }
        Returns: undefined
      }
      erp_my_approvals: { Args: never; Returns: Json }
      erp_my_tenants: { Args: never; Returns: Json }
      erp_onboard_tenant: {
        Args: { p_code: string; p_name: string }
        Returns: Json
      }
      erp_open_change_request: {
        Args: {
          p_object_id: string
          p_object_type: string
          p_proposed: Json
          p_reason?: string
        }
        Returns: string
      }
      erp_open_mass_change: {
        Args: {
          p_changes: Json
          p_code?: string
          p_object_type: string
          p_reason?: string
          p_selector: Json
        }
        Returns: string
      }
      erp_open_period_close: {
        Args: { p_fiscal_period_id: string }
        Returns: number
      }
      erp_override_posting_account: {
        Args: {
          p_account_id: string
          p_dimensions?: Json
          p_line_ref?: string
          p_object_id: string
          p_object_type: string
          p_reason: string
        }
        Returns: Json
      }
      erp_part5_coverage: { Args: { p_section?: string }; Returns: Json }
      erp_part5_summary: { Args: never; Returns: Json }
      erp_parties: {
        Args: { p_role_kind?: string; p_search?: string }
        Returns: Json
      }
      erp_party_posting_classes: { Args: { p_limit?: number }; Returns: Json }
      erp_payment_proposals: { Args: { p_limit?: number }; Returns: Json }
      erp_permissions_directory: { Args: never; Returns: Json }
      erp_plan_shipment: {
        Args: {
          p_delivery_ids: string[]
          p_planned_despatch?: string
          p_site_id: string
        }
        Returns: string
      }
      erp_planned_orders: {
        Args: { p_limit?: number; p_site_id?: string }
        Returns: Json
      }
      erp_planner_workbench: { Args: { p_site_id?: string }; Returns: Json }
      erp_planning_exceptions: { Args: { p_limit?: number }; Returns: Json }
      erp_platform_add_staff: {
        Args: { p_display_name: string; p_email: string; p_role: string }
        Returns: Json
      }
      erp_platform_assurance: { Args: never; Returns: Json }
      erp_platform_audit: {
        Args: { p_action?: string; p_limit?: number; p_tenant_id?: string }
        Returns: Json
      }
      erp_platform_cancel_ownership_transfer: {
        Args: { p_reason?: string; p_transfer_id: string }
        Returns: Json
      }
      erp_platform_claim_ownership: {
        Args: { p_display_name?: string }
        Returns: Json
      }
      erp_platform_enter_tenant: {
        Args: { p_reason: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_invite_admin: {
        Args: { p_display_name: string; p_email: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_leave_tenant: {
        Args: { p_tenant_id: string }
        Returns: Json
      }
      erp_platform_me: { Args: never; Returns: Json }
      erp_platform_offer_ownership: {
        Args: { p_reason?: string; p_tenant_id: string; p_to_staff_id: string }
        Returns: Json
      }
      erp_platform_onboard_company: {
        Args: {
          p_admin_display_name: string
          p_admin_email: string
          p_base_currency?: string
          p_code: string
          p_country_code?: string
          p_name: string
          p_timezone?: string
        }
        Returns: Json
      }
      erp_platform_ownership_transfers: {
        Args: { p_limit?: number; p_tenant_id?: string }
        Returns: Json
      }
      erp_platform_respond_ownership_transfer: {
        Args: { p_accept: boolean; p_note?: string; p_transfer_id: string }
        Returns: Json
      }
      erp_platform_revoke_staff: {
        Args: { p_id: string; p_reason?: string }
        Returns: Json
      }
      erp_platform_set_staff_role: {
        Args: { p_id: string; p_role: string }
        Returns: Json
      }
      erp_platform_set_tenant_status: {
        Args: { p_reason?: string; p_status: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_staff: { Args: never; Returns: Json }
      erp_platform_tenants: { Args: never; Returns: Json }
      erp_post_count: { Args: { p_task_id: string }; Returns: number }
      erp_posting_classes: { Args: { p_kind?: string }; Returns: Json }
      erp_posting_overrides: { Args: { p_limit?: number }; Returns: Json }
      erp_preview_approval_chain: {
        Args: {
          p_currency?: string
          p_department_id?: string
          p_object_type: string
          p_requester?: string
          p_value_minor: number
        }
        Returns: Json
      }
      erp_preview_import: { Args: { p_batch_id: string }; Returns: Json }
      erp_price_document_line: { Args: { p_line_id: string }; Returns: number }
      erp_principals: { Args: never; Returns: Json }
      erp_promise_date: {
        Args: { p_item_id: string; p_quantity: number; p_site_id: string }
        Returns: string
      }
      erp_promote_change_set: {
        Args: { p_change_set_id: string }
        Returns: Json
      }
      erp_propose_payment_run: {
        Args: {
          p_currency?: string
          p_include_due_within?: string
          p_payment_date?: string
        }
        Returns: string
      }
      erp_protected_values: { Args: never; Returns: Json }
      erp_put_protected_value: {
        Args: { p_code: string; p_value: string }
        Returns: Json
      }
      erp_qualify_supplier: {
        Args: { p_note?: string; p_party_id: string; p_valid_for?: string }
        Returns: undefined
      }
      erp_quality_events: { Args: { p_limit?: number }; Returns: Json }
      erp_raise_count_tasks: {
        Args: { p_programme_code: string }
        Returns: number
      }
      erp_raise_customer_return: {
        Args: {
          p_original_document_id: string
          p_outcome?: string
          p_reason: string
          p_reason_code: string
        }
        Returns: string
      }
      erp_raise_putaway_tasks: { Args: { p_site_id: string }; Returns: number }
      erp_raise_quality_event: {
        Args: {
          p_batch_id?: string
          p_document_id?: string
          p_due_in?: string
          p_item_id?: string
          p_kind:
            | "deviation"
            | "non_conformance"
            | "complaint"
            | "excursion"
            | "near_miss"
            | "audit_finding"
          p_party_id?: string
          p_severity: string
          p_site_id?: string
          p_title: string
        }
        Returns: string
      }
      erp_raise_recall: {
        Args: {
          p_batch_ids: string[]
          p_classification: string
          p_clock_code?: string
          p_reason: string
          p_title: string
        }
        Returns: string
      }
      erp_raise_replenishment_tasks: {
        Args: { p_site_id: string }
        Returns: number
      }
      erp_raise_works_order: {
        Args: {
          p_item_id: string
          p_kind?:
            | "assembly"
            | "kitting"
            | "rework"
            | "repackaging"
            | "disassembly"
          p_planned_end?: string
          p_quantity: number
          p_site_id: string
        }
        Returns: string
      }
      erp_read_protected_value: { Args: { p_code: string }; Returns: Json }
      erp_recall_evidence: { Args: { p_recall_id: string }; Returns: Json }
      erp_recall_readiness: { Args: { p_recall_id?: string }; Returns: Json }
      erp_recalls: { Args: never; Returns: Json }
      erp_receivables_ageing: { Args: { p_as_at?: string }; Returns: Json }
      erp_receive_against: {
        Args: {
          p_batch_id?: string
          p_order_line_id: string
          p_quantity: number
          p_receipt_id: string
        }
        Returns: string
      }
      erp_receive_works_order_output: {
        Args: {
          p_batch_number?: string
          p_location_id?: string
          p_quantity: number
          p_works_order_id: string
        }
        Returns: string
      }
      erp_record_count: {
        Args: { p_quantity: number; p_task_id: string }
        Returns:
          | "open"
          | "counted"
          | "pending_approval"
          | "approved"
          | "rejected"
          | "posted"
          | "cancelled"
      }
      erp_record_inspection_result: {
        Args: {
          p_characteristic: string
          p_inspection_id: string
          p_instrument?: string
          p_numeric_value?: number
          p_text_value?: string
        }
        Returns: boolean
      }
      erp_record_proof_of_delivery: {
        Args: {
          p_arrived_at: string
          p_reference?: string
          p_shipment_id: string
          p_signed_by: string
        }
        Returns: undefined
      }
      erp_redistribution_suggestions: {
        Args: { p_days?: number }
        Returns: Json
      }
      erp_release_batch: {
        Args: {
          p_basis: string
          p_batch_id: string
          p_inspection_id?: string
          p_signature: string
          p_site_id: string
        }
        Returns: string
      }
      erp_release_credit_hold: {
        Args: { p_document_id: string; p_reason: string }
        Returns: undefined
      }
      erp_release_sequence: {
        Args: { p_limit?: number; p_site_id?: string }
        Returns: Json
      }
      erp_release_works_order: {
        Args: { p_allow_shortage?: boolean; p_works_order_id: string }
        Returns:
          | "draft"
          | "planned"
          | "released"
          | "in_progress"
          | "completed"
          | "closed"
          | "cancelled"
      }
      erp_reopen_period: {
        Args: { p_fiscal_period_id: string; p_reason: string }
        Returns: number
      }
      erp_replay_message: {
        Args: { p_message_id: number; p_reason: string }
        Returns: number
      }
      erp_request_tenant_deletion: {
        Args: { p_confirm_code: string; p_reason: string }
        Returns: Json
      }
      erp_reserve_for_line: {
        Args: { p_document_line_id: string; p_policy_code?: string }
        Returns: string
      }
      erp_resolve_price: {
        Args: { p_item_id: string; p_party_id: string; p_quantity?: number }
        Returns: Json
      }
      erp_resolve_purchase_price: {
        Args: {
          p_item_id: string
          p_on?: string
          p_party_id: string
          p_quantity?: number
          p_site_id?: string
        }
        Returns: Json
      }
      erp_resource_catalog: { Args: { p_locale?: string }; Returns: Json }
      erp_resources: { Args: { p_locale?: string }; Returns: Json }
      erp_retire_account_determination: {
        Args: { p_rule_id: string }
        Returns: Json
      }
      erp_retire_approval_band: { Args: { p_band_id: string }; Returns: Json }
      erp_retire_posting_class: {
        Args: { p_posting_class_id: string }
        Returns: Json
      }
      erp_return_reasons: { Args: { p_days?: number }; Returns: Json }
      erp_reverse_mass_change: {
        Args: { p_mass_change_id: string }
        Returns: number
      }
      erp_revoke_role: { Args: { p_user_role_id: string }; Returns: Json }
      erp_rollback_import: { Args: { p_batch_id: string }; Returns: Json }
      erp_rollback_to_snapshot: {
        Args: { p_reason: string; p_snapshot_id: string }
        Returns: string
      }
      erp_rotate_tenant_key: {
        Args: { p_purpose?: string; p_reason?: string }
        Returns: Json
      }
      erp_run_forecast: {
        Args: {
          p_buckets?: number
          p_forecast_code: string
          p_periods?: number
        }
        Returns: string
      }
      erp_run_planning: {
        Args: { p_horizon_days?: number; p_site_id: string }
        Returns: string
      }
      erp_save_role: {
        Args: {
          p_code: string
          p_description: string
          p_name: string
          p_permissions: string[]
          p_role_id: string
        }
        Returns: Json
      }
      erp_seed_demo: { Args: never; Returns: Json }
      erp_seed_demo_operations: { Args: never; Returns: Json }
      erp_select_carrier: {
        Args: { p_required_by?: string; p_shipment_id: string }
        Returns: Json
      }
      erp_session: { Args: never; Returns: Json }
      erp_set_account_dimension_requirements: {
        Args: { p_account_id: string; p_dimension_codes: string }
        Returns: Json
      }
      erp_set_active_tenant: { Args: { p_tenant_id: string }; Returns: Json }
      erp_set_item_posting_class: {
        Args: {
          p_item_id: string
          p_posting_class_id: string
          p_reason?: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_set_kill_switch: {
        Args: {
          p_key: string
          p_kind:
            | "rule_set"
            | "rule"
            | "state_machine"
            | "approval_chain"
            | "job"
            | "command_class"
            | "integration"
            | "event_consumer"
          p_reason: string
        }
        Returns: string
      }
      erp_set_party_posting_class: {
        Args: {
          p_party_id: string
          p_posting_class_id: string
          p_reason?: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_set_resource_override: {
        Args: {
          p_key: string
          p_locale?: string
          p_note?: string
          p_value: string
        }
        Returns: Json
      }
      erp_shipments: { Args: { p_limit?: number }; Returns: Json }
      erp_sign_off_forecast: {
        Args: { p_note?: string; p_version_id: string }
        Returns: undefined
      }
      erp_silent_jobs: { Args: never; Returns: Json }
      erp_split_batch: {
        Args: {
          p_batch_id: string
          p_location_id: string
          p_new_number: string
          p_quantity: number
          p_reason: string
        }
        Returns: string
      }
      erp_stage_import: {
        Args: {
          p_code?: string
          p_object_type: string
          p_rows: Json
          p_source?: string
        }
        Returns: string
      }
      erp_stamp_approval_routing: {
        Args: {
          p_currency?: string
          p_department_id?: string
          p_object_id: string
          p_object_type: string
          p_value_minor: number
        }
        Returns: Json
      }
      erp_stamp_document_approval: {
        Args: { p_document_id: string }
        Returns: Json
      }
      erp_stock_ageing: { Args: never; Returns: Json }
      erp_stock_health: { Args: never; Returns: Json }
      erp_stock_provision: { Args: never; Returns: Json }
      erp_stock_valuation: { Args: never; Returns: Json }
      erp_submit_change_request: {
        Args: { p_request_id: string }
        Returns: Json
      }
      erp_submit_command: {
        Args: {
          p_dry_run?: boolean
          p_idempotency_key?: string
          p_operation_code: string
          p_payload?: Json
          p_system_code: string
        }
        Returns: Json
      }
      erp_supplier_qualification: { Args: never; Returns: Json }
      erp_supply_demand: {
        Args: { p_horizon_days?: number; p_item_id: string; p_site_id: string }
        Returns: Json
      }
      erp_tax_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      erp_tenant_keys: { Args: never; Returns: Json }
      erp_transition_document: {
        Args: {
          p_document_id: string
          p_reason?: string
          p_transition_code: string
        }
        Returns: Json
      }
      erp_trial_balance: { Args: never; Returns: Json }
      erp_trigger_job: {
        Args: { p_job_code: string; p_reason?: string }
        Returns: Json
      }
      erp_upsert_account_determination: {
        Args: {
          p_account_id: string
          p_dimensions?: Json
          p_entity_id?: string
          p_item_class_id?: string
          p_ledger_id?: string
          p_legislation_pack_code?: string
          p_note?: string
          p_party_class_id?: string
          p_reason_code?: string
          p_site_id?: string
          p_transaction_type: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_upsert_approval_band: {
        Args: {
          p_approver_role_code?: string
          p_approver_user_id?: string
          p_currency?: string
          p_department_id: string
          p_escalate_after_hours?: number
          p_is_parallel?: boolean
          p_lower_bound_minor?: number
          p_object_type: string
          p_rerun_lower_bands?: boolean
          p_seq: number
          p_tolerance_pct?: number
          p_upper_bound_minor?: number
          p_use_line_manager?: boolean
          p_vacancy?: string
        }
        Returns: Json
      }
      erp_upsert_department: {
        Args: {
          p_code: string
          p_default_cost_centre?: string
          p_entity_id?: string
          p_manager_user_id?: string
          p_name: string
          p_parent_department_id?: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_upsert_dimension_rule: {
        Args: {
          p_code: string
          p_condition: Json
          p_effect?: string
          p_entity_id?: string
          p_message?: string
          p_name: string
        }
        Returns: Json
      }
      erp_upsert_posting_class: {
        Args: {
          p_code: string
          p_description?: string
          p_kind: string
          p_name: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_validate_import: { Args: { p_batch_id: string }; Returns: Json }
      erp_warehouse_tasks: {
        Args: { p_kind?: string; p_limit?: number; p_site_id?: string }
        Returns: Json
      }
      erp_works_order_availability: {
        Args: { p_works_order_id: string }
        Returns: Json
      }
      erp_works_order_variance: {
        Args: { p_works_order_id: string }
        Returns: Json
      }
      erp_works_orders: { Args: { p_limit?: number }; Returns: Json }
      erp_write_off_stock: {
        Args: {
          p_batch_id?: string
          p_item_id: string
          p_location_id: string
          p_quantity: number
          p_reason: string
          p_site_id: string
        }
        Returns: number
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
