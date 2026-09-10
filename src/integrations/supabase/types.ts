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
      erp_accessibility_statement: { Args: never; Returns: Json }
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
      erp_add_quote_line: {
        Args: {
          p_discount_pct?: number
          p_document_id: string
          p_item_code: string
          p_quantity?: number
        }
        Returns: string
      }
      erp_add_report_pack_item: {
        Args: {
          p_pack_code: string
          p_parameters?: Json
          p_report_code: string
          p_seq?: number
        }
        Returns: string
      }
      erp_add_wave_line: {
        Args: {
          p_document_id?: string
          p_item_id: string
          p_quantity: number
          p_wave_id: string
        }
        Returns: Json
      }
      erp_adjust_forecast_line: {
        Args: { p_line_id: string; p_quantity: number; p_reason: string }
        Returns: undefined
      }
      erp_adoption_signals: { Args: never; Returns: Json }
      erp_age_back_release_area: {
        Args: { p_release_area_id: string }
        Returns: Json
      }
      erp_allocate_landed_cost: {
        Args: { p_landed_cost_id: string }
        Returns: number
      }
      erp_allocate_release_wave: { Args: { p_wave_id: string }; Returns: Json }
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
      erp_analytics_contract: { Args: never; Returns: Json }
      erp_analytics_read: {
        Args: {
          p_limit?: number
          p_since?: string
          p_token: string
          p_view_code: string
        }
        Returns: Json
      }
      erp_answer_interview: {
        Args: { p_answer: Json; p_question_code: string; p_session_id: string }
        Returns: Json
      }
      erp_answer_pack_decision: {
        Args: {
          p_answer: Json
          p_object_key: string
          p_object_kind: string
          p_pack_code: string
        }
        Returns: Json
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
      erp_apply_content_pack: {
        Args: { p_change_set_code?: string; p_pack_code: string }
        Returns: Json
      }
      erp_apply_mass_change: {
        Args: { p_mass_change_id: string }
        Returns: number
      }
      erp_apply_preset: {
        Args: { p_code: string; p_reason?: string }
        Returns: Json
      }
      erp_apply_settlement_statement: {
        Args: { p_statement_id: string }
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
      erp_approve_quote: { Args: { p_document_id: string }; Returns: string }
      erp_approver_assignments: {
        Args: { p_object_type?: string }
        Returns: Json
      }
      erp_assemble_report_pack: { Args: { p_pack_code: string }; Returns: Json }
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
          p_currency?: string
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
      erp_bill_from_receipt: {
        Args: {
          p_due_date?: string
          p_invoice_date?: string
          p_receipt_id: string
          p_their_reference?: string
        }
        Returns: Json
      }
      erp_blanket_position: { Args: { p_blanket_id: string }; Returns: Json }
      erp_block_location: {
        Args: { p_location_id: string; p_reason_code?: string }
        Returns: string
      }
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
      erp_call_off_blanket_order: {
        Args: { p_blanket_id: string; p_lines: Json }
        Returns: string
      }
      erp_cancel_command: {
        Args: { p_command_id: string; p_reason: string }
        Returns: undefined
      }
      erp_capabilities: { Args: never; Returns: Json }
      erp_change_requests: { Args: { p_object_type?: string }; Returns: Json }
      erp_change_sets: { Args: never; Returns: Json }
      erp_chart_alternative: { Args: never; Returns: Json }
      erp_check_training_run: { Args: { p_run_id: string }; Returns: Json }
      erp_claim_invitation: { Args: { p_token: string }; Returns: Json }
      erp_classification_axes: { Args: never; Returns: Json }
      erp_classification_gaps: { Args: { p_limit?: number }; Returns: Json }
      erp_classification_values: { Args: { p_axis_id?: string }; Returns: Json }
      erp_classify_item: {
        Args: {
          p_axis_id: string
          p_item_id: string
          p_valid_from?: string
          p_value_id: string
        }
        Returns: Json
      }
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
      erp_close_device_session: {
        Args: { p_end_reason?: string }
        Returns: Json
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
      erp_code_divergences: { Args: { p_limit?: number }; Returns: Json }
      erp_code_templates: { Args: never; Returns: Json }
      erp_commercial_quote: { Args: { p_document_id: string }; Returns: Json }
      erp_commercial_quotes: { Args: never; Returns: Json }
      erp_commercial_renewals: { Args: never; Returns: Json }
      erp_commercial_summary: { Args: never; Returns: Json }
      erp_commit_allocation: {
        Args: {
          p_allocation_id: string
          p_batch_id?: string
          p_location_id?: string
        }
        Returns: number
      }
      erp_compare_planning_runs: {
        Args: { p_run_a: string; p_run_b: string }
        Returns: Json
      }
      erp_complete_close_task: {
        Args: { p_task_id: string; p_waiver_reason?: string }
        Returns: string
      }
      erp_complete_warehouse_task: {
        Args: { p_quantity?: number; p_task_id: string }
        Returns: Json
      }
      erp_configuration_columns: {
        Args: { p_object_type?: string }
        Returns: Json
      }
      erp_configure_commercial: {
        Args: { p_approver_role?: string; p_discount_threshold_pct?: number }
        Returns: string
      }
      erp_configure_consolidation: {
        Args: { p_member_entity_ids?: string[]; p_parent_entity_id: string }
        Returns: string
      }
      erp_configure_finance: {
        Args: {
          p_currency?: string
          p_entity_id?: string
          p_fiscal_year?: number
        }
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
      erp_configure_notifications: { Args: never; Returns: string }
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
      erp_configure_reporting: { Args: never; Returns: string }
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
      erp_confirm_delivery: {
        Args: { p_delivery_id: string }
        Returns: undefined
      }
      erp_confirm_drop_ship: {
        Args: {
          p_delivered_on?: string
          p_purchase_order_id: string
          p_reference?: string
        }
        Returns: undefined
      }
      erp_consolidated_trial_balance: {
        Args: { p_as_at?: string; p_parent_entity_id: string }
        Returns: Json
      }
      erp_consume_consignment: {
        Args: {
          p_batch_id?: string
          p_item_id: string
          p_location_id: string
          p_quantity: number
          p_reason?: string
          p_site_id: string
          p_supplier_party_id: string
        }
        Returns: number
      }
      erp_container_identity_policies: { Args: never; Returns: Json }
      erp_content_packs: { Args: never; Returns: Json }
      erp_convert_document: {
        Args: {
          p_document_id: string
          p_lines?: Json
          p_party_id?: string
          p_site_id?: string
          p_transition?: string
        }
        Returns: Json
      }
      erp_count_accuracy: { Args: never; Returns: Json }
      erp_count_tasks: { Args: { p_limit?: number }; Returns: Json }
      erp_create_batch: {
        Args: {
          p_batch_number: string
          p_expires_on?: string
          p_item_id: string
          p_manufactured_on?: string
          p_supplier_party_id?: string
        }
        Returns: string
      }
      erp_create_classified_item: {
        Args: {
          p_classification?: Json
          p_is_batch_controlled?: boolean
          p_item_class: string
          p_name: string
          p_template_id: string
        }
        Returns: Json
      }
      erp_create_document: {
        Args: {
          p_currency?: string
          p_entity_id?: string
          p_party_id?: string
          p_required_date?: string
          p_site_id?: string
          p_stock_owner_party_id?: string
          p_their_ref?: string
          p_type_code: string
        }
        Returns: Json
      }
      erp_create_document_full: {
        Args: {
          p_currency?: string
          p_lines?: Json
          p_party_id?: string
          p_required_date?: string
          p_site_id?: string
          p_their_ref?: string
          p_transition?: string
          p_type_code: string
        }
        Returns: Json
      }
      erp_create_entity: {
        Args: {
          p_base_currency?: string
          p_code: string
          p_country_code?: string
          p_document_locale?: string
          p_fiscal_year_start_month?: number
          p_legal_name?: string
          p_name: string
          p_parent_code?: string
          p_reporting_locale?: string
        }
        Returns: string
      }
      erp_create_handling_unit: {
        Args: {
          p_code?: string
          p_container_type: string
          p_item_id?: string
          p_location_id: string
          p_parent_container_id?: string
          p_site_id: string
        }
        Returns: string
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
      erp_create_location: {
        Args: {
          p_capacity_quantity?: number
          p_capacity_uom?: string
          p_code: string
          p_count_class?: string
          p_is_pickable?: boolean
          p_location_type?: string
          p_name?: string
          p_parent_location_id?: string
          p_site_id: string
        }
        Returns: string
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
      erp_create_party_with_roles: {
        Args: {
          p_code: string
          p_country_code?: string
          p_legal_name?: string
          p_name: string
          p_role_kinds?: string[]
        }
        Returns: Json
      }
      erp_create_service_principal: {
        Args: { p_display_name: string }
        Returns: Json
      }
      erp_create_site: {
        Args: {
          p_code: string
          p_country_code?: string
          p_entity_id?: string
          p_name?: string
          p_operator_party_id?: string
          p_site_type?: string
          p_timezone?: string
        }
        Returns: Json
      }
      erp_create_storage_rule: {
        Args: {
          p_item_class?: string
          p_item_id?: string
          p_location_id: string
          p_max_quantity?: number
          p_priority?: number
          p_rule_kind?: string
          p_site_id: string
        }
        Returns: string
      }
      erp_create_uom: {
        Args: {
          p_code: string
          p_decimals?: number
          p_is_base?: boolean
          p_name: string
          p_uom_class?: string
        }
        Returns: Json
      }
      erp_credit_position: { Args: { p_party_id: string }; Returns: Json }
      erp_currencies: { Args: never; Returns: Json }
      erp_cut_over_domain: {
        Args: { p_domain_code: string; p_note?: string }
        Returns: Json
      }
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
      erp_dependent_demand: {
        Args: { p_limit?: number; p_planning_run_id?: string }
        Returns: Json
      }
      erp_determination_coverage: { Args: never; Returns: Json }
      erp_determination_coverage_report: { Args: never; Returns: Json }
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
      erp_device_actions: { Args: never; Returns: Json }
      erp_device_classes: { Args: never; Returns: Json }
      erp_device_operations: { Args: never; Returns: Json }
      erp_device_queue: { Args: { p_device_code: string }; Returns: Json }
      erp_device_stock_position: {
        Args: { p_device_code?: string; p_reference_id: string }
        Returns: Json
      }
      erp_device_task_handlers: { Args: never; Returns: Json }
      erp_device_tasks: { Args: never; Returns: Json }
      erp_devices: { Args: never; Returns: Json }
      erp_dimension_rules: { Args: never; Returns: Json }
      erp_dimension_values: {
        Args: { p_dimension_code?: string }
        Returns: Json
      }
      erp_dimensions: { Args: never; Returns: Json }
      erp_dismiss_first_run_step: {
        Args: { p_dismissed?: boolean; p_guide_code: string; p_seq: number }
        Returns: Json
      }
      erp_dispatch_evidence: { Args: never; Returns: Json }
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
      erp_domain_cutovers: { Args: never; Returns: Json }
      erp_drain_device_actions: {
        Args: { p_device_code?: string; p_limit?: number }
        Returns: Json
      }
      erp_dunning_worklist: { Args: never; Returns: Json }
      erp_duplicate_candidates: {
        Args: { p_object_type: string }
        Returns: Json
      }
      erp_eliminations: {
        Args: { p_limit?: number; p_parent_entity_id: string }
        Returns: Json
      }
      erp_email_readiness: { Args: never; Returns: Json }
      erp_email_suppressions: { Args: never; Returns: Json }
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
      erp_end_item_supplier: {
        Args: { p_item_supplier_id: string; p_reason?: string }
        Returns: Json
      }
      erp_entities: { Args: never; Returns: Json }
      erp_erasure_requests: { Args: never; Returns: Json }
      erp_erasure_subjects: { Args: never; Returns: Json }
      erp_excursion_impact: {
        Args: {
          p_from: string
          p_location_id: string
          p_site_id: string
          p_to: string
        }
        Returns: Json
      }
      erp_execute_erasure: { Args: { p_request_id: string }; Returns: Json }
      erp_expiry_horizon: { Args: { p_days?: number }; Returns: Json }
      erp_export_configuration: {
        Args: { p_object_type: string }
        Returns: Json
      }
      erp_export_tenant: { Args: never; Returns: Json }
      erp_expose_governed_view: {
        Args: { p_view_code: string }
        Returns: number
      }
      erp_fail_delivery: {
        Args: { p_delivery_id: string; p_reason: string }
        Returns: undefined
      }
      erp_firm_planned_order: {
        Args: { p_document_type_code?: string; p_planned_order_id: string }
        Returns: string
      }
      erp_first_run_guide: { Args: never; Returns: Json }
      erp_fiscal_periods: { Args: never; Returns: Json }
      erp_fixed_asset_register: { Args: { p_as_at?: string }; Returns: Json }
      erp_forecast_events: { Args: never; Returns: Json }
      erp_forecast_lines: {
        Args: { p_limit?: number; p_version_id: string }
        Returns: Json
      }
      erp_forecast_versions: { Args: { p_limit?: number }; Returns: Json }
      erp_glossary: { Args: never; Returns: Json }
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
      erp_gs1_application_identifiers: { Args: never; Returns: Json }
      erp_hand_over_custody: {
        Args: {
          p_batch_id?: string
          p_item_id: string
          p_keeper_party_id: string
          p_location_id: string
          p_quantity: number
          p_reason?: string
          p_site_id: string
        }
        Returns: number
      }
      erp_help_topic: { Args: { p_screen_path: string }; Returns: Json }
      erp_help_topics: { Args: never; Returns: Json }
      erp_import_batches: { Args: { p_limit?: number }; Returns: Json }
      erp_import_configuration: {
        Args: { p_dry_run?: boolean; p_object_type: string; p_rows: Json }
        Returns: Json
      }
      erp_incident_history: { Args: never; Returns: Json }
      erp_incident_subscription: { Args: never; Returns: Json }
      erp_inspections: { Args: { p_limit?: number }; Returns: Json }
      erp_integration_backlog: { Args: { p_limit?: number }; Returns: Json }
      erp_integration_health: { Args: never; Returns: Json }
      erp_intercompany_position: { Args: never; Returns: Json }
      erp_interview_questions: { Args: { p_session_id: string }; Returns: Json }
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
      erp_is_platform_organisation: { Args: never; Returns: boolean }
      erp_issue_analytics_credential: {
        Args: {
          p_expires_at?: string
          p_label: string
          p_view_codes?: string[]
        }
        Returns: Json
      }
      erp_issue_quote: { Args: { p_document_id: string }; Returns: Json }
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
      erp_item_classification: { Args: { p_item_id: string }; Returns: Json }
      erp_item_code_assignments: { Args: { p_limit?: number }; Returns: Json }
      erp_item_posting_classes: { Args: { p_limit?: number }; Returns: Json }
      erp_item_suppliers: {
        Args: { p_item_id?: string; p_site_id?: string }
        Returns: Json
      }
      erp_items: {
        Args: { p_limit?: number; p_search?: string }
        Returns: Json
      }
      erp_job_handlers: { Args: never; Returns: Json }
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
            | "mirrors"
          p_quantity?: number
          p_to_document_id: string
        }
        Returns: string
      }
      erp_load_import: { Args: { p_batch_id: string }; Returns: number }
      erp_locales: { Args: never; Returns: Json }
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
      erp_mark_first_run_step: {
        Args: { p_done?: boolean; p_guide_code: string; p_seq: number }
        Returns: Json
      }
      erp_mark_notification_read: {
        Args: { p_notification_id: string }
        Returns: undefined
      }
      erp_match_settlement_line: {
        Args: { p_line_id: string; p_note: string; p_subledger_item_id: string }
        Returns: undefined
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
      erp_migration_domains: { Args: never; Returns: Json }
      erp_module_installations: { Args: never; Returns: Json }
      erp_module_upgrade_plan: {
        Args: { p_install_code: string }
        Returns: Json
      }
      erp_my_agreement: { Args: never; Returns: Json }
      erp_my_approvals: { Args: never; Returns: Json }
      erp_my_contract_document: {
        Args: { p_document_id: string }
        Returns: Json
      }
      erp_my_notification_settings: { Args: never; Returns: Json }
      erp_my_notifications: { Args: { p_limit?: number }; Returns: Json }
      erp_my_tenants: { Args: never; Returns: Json }
      erp_notice_periods: { Args: never; Returns: Json }
      erp_notification_channels: {
        Args: never
        Returns: {
          code: string
          credential_ref: string
          id: string
          is_enabled: boolean
          kind: string
          name: string
          settings: Json
          updated_at: string
        }[]
      }
      erp_notification_health: { Args: never; Returns: Json }
      erp_notification_routes: { Args: never; Returns: Json }
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
      erp_open_commercial_quote: {
        Args: {
          p_currency?: string
          p_customer_tenant_code?: string
          p_notes?: string
          p_party_code: string
          p_party_name: string
          p_price_book_code: string
          p_term_kind?: string
          p_term_months?: number
          p_valid_days?: number
        }
        Returns: string
      }
      erp_open_device_session: {
        Args: {
          p_device_code: string
          p_supervisor_reason?: string
          p_supervisor_user_id?: string
        }
        Returns: Json
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
      erp_open_price_book: {
        Args: {
          p_code: string
          p_currencies: string[]
          p_effective_from?: string
          p_name: string
          p_note?: string
        }
        Returns: string
      }
      erp_open_release_wave: {
        Args: { p_code?: string; p_note?: string; p_release_area_id: string }
        Returns: Json
      }
      erp_open_renewal_quote: {
        Args: { p_renewal_id: string }
        Returns: string
      }
      erp_opening_balance_reconciliation: {
        Args: { p_batch_id: string }
        Returns: Json
      }
      erp_opening_batches: { Args: never; Returns: Json }
      erp_order_behaviours: { Args: never; Returns: Json }
      erp_output_health: { Args: never; Returns: Json }
      erp_output_integrity: { Args: never; Returns: Json }
      erp_output_requests: { Args: never; Returns: Json }
      erp_output_template_versions: { Args: never; Returns: Json }
      erp_output_templates: { Args: never; Returns: Json }
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
      erp_pack_acceptance: { Args: never; Returns: Json }
      erp_pack_plan: { Args: { p_pack_code: string }; Returns: Json }
      erp_parallel_run_figures: { Args: never; Returns: Json }
      erp_part5_coverage: { Args: { p_section?: string }; Returns: Json }
      erp_part5_summary: { Args: never; Returns: Json }
      erp_parties: {
        Args: { p_limit?: number; p_role_kind?: string; p_search?: string }
        Returns: Json
      }
      erp_party_posting_classes: { Args: { p_limit?: number }; Returns: Json }
      erp_pay_payment_run: { Args: { p_proposal_id: string }; Returns: Json }
      erp_payables_ageing: { Args: { p_as_at?: string }; Returns: Json }
      erp_payment_proposal_lines: {
        Args: { p_proposal_id: string }
        Returns: Json
      }
      erp_payment_proposals: { Args: { p_limit?: number }; Returns: Json }
      erp_permissions_directory: { Args: never; Returns: Json }
      erp_personal_data_register: { Args: never; Returns: Json }
      erp_pick_document: {
        Args: {
          p_batch_id?: string
          p_document_id: string
          p_location_id?: string
        }
        Returns: Json
      }
      erp_plan_shipment: {
        Args: {
          p_delivery_ids: string[]
          p_planned_despatch?: string
          p_site_id: string
        }
        Returns: string
      }
      erp_planned_order_pegging: {
        Args: { p_planned_order_id: string }
        Returns: Json
      }
      erp_planned_orders: {
        Args: {
          p_limit?: number
          p_planning_run_id?: string
          p_site_id?: string
        }
        Returns: Json
      }
      erp_planner_workbench: { Args: { p_site_id?: string }; Returns: Json }
      erp_planning_exceptions: {
        Args: { p_limit?: number; p_planning_run_id?: string }
        Returns: Json
      }
      erp_planning_runs: {
        Args: { p_limit?: number; p_site_id?: string }
        Returns: Json
      }
      erp_platform_add_incident_action: {
        Args: {
          p_code: string
          p_description: string
          p_due_on?: string
          p_owner: string
        }
        Returns: string
      }
      erp_platform_add_staff: {
        Args: { p_display_name: string; p_email: string; p_role: string }
        Returns: Json
      }
      erp_platform_amend_contract: {
        Args: {
          p_changes: Json
          p_contract_id: string
          p_effective_from: string
          p_rationale?: string
          p_title: string
        }
        Returns: string
      }
      erp_platform_announce_maintenance: {
        Args: {
          p_affects_all_tenants: boolean
          p_code: string
          p_detail: string
          p_emergency_reason?: string
          p_ends_at: string
          p_is_emergency?: boolean
          p_starts_at: string
          p_tenant_codes?: string[]
          p_title: string
        }
        Returns: string
      }
      erp_platform_assemble_incident_review: {
        Args: { p_code: string }
        Returns: Json
      }
      erp_platform_assurance: { Args: never; Returns: Json }
      erp_platform_attach_contract_document: {
        Args: {
          p_content: string
          p_contract_id: string
          p_kind: string
          p_title: string
        }
        Returns: string
      }
      erp_platform_audit: {
        Args: { p_action?: string; p_limit?: number; p_tenant_id?: string }
        Returns: Json
      }
      erp_platform_cancel_maintenance: {
        Args: { p_code: string; p_reason: string }
        Returns: undefined
      }
      erp_platform_cancel_ownership_transfer: {
        Args: { p_reason?: string; p_transfer_id: string }
        Returns: Json
      }
      erp_platform_claim_ownership: {
        Args: { p_display_name?: string }
        Returns: Json
      }
      erp_platform_commercial_state: { Args: never; Returns: Json }
      erp_platform_complete_incident_action: {
        Args: { p_action_id: string; p_note: string }
        Returns: undefined
      }
      erp_platform_components: { Args: never; Returns: Json }
      erp_platform_contain_incident: {
        Args: {
          p_affects_all_tenants: boolean
          p_code: string
          p_scope: string
        }
        Returns: undefined
      }
      erp_platform_continuity: { Args: never; Returns: Json }
      erp_platform_contract: { Args: { p_contract_id: string }; Returns: Json }
      erp_platform_contract_document: {
        Args: { p_document_id: string }
        Returns: Json
      }
      erp_platform_contracts: { Args: never; Returns: Json }
      erp_platform_create_contract: {
        Args: {
          p_billing_frequency?: string
          p_commencement: string
          p_customer_legal_name: string
          p_customer_tenant_code: string
          p_governing_law?: string
          p_initial_term_months?: number
          p_lead_days?: number
          p_notice_days?: number
          p_platform_legal_name: string
          p_quote_document_id: string
          p_renewal_kind?: string
          p_review_date?: string
          p_termination_terms?: Json
          p_uplift_rule?: Json
        }
        Returns: string
      }
      erp_platform_declare_incident: {
        Args: {
          p_affects_all_tenants?: boolean
          p_code: string
          p_commander: string
          p_communications_owner: string
          p_components?: string[]
          p_is_data_integrity?: boolean
          p_next_update_minutes?: number
          p_scope?: string
          p_scribe: string
          p_severity_code: string
          p_tenant_codes?: string[]
          p_title: string
        }
        Returns: string
      }
      erp_platform_decline_renewal: {
        Args: { p_note: string; p_renewal_id: string }
        Returns: undefined
      }
      erp_platform_dependencies: { Args: never; Returns: Json }
      erp_platform_deployment_state: { Args: never; Returns: Json }
      erp_platform_designate_organisation: {
        Args: { p_reason?: string; p_tenant_code: string }
        Returns: string
      }
      erp_platform_diagnostics: { Args: never; Returns: Json }
      erp_platform_disclosures: { Args: never; Returns: Json }
      erp_platform_enquiries: { Args: { p_limit?: number }; Returns: Json }
      erp_platform_ensure_schedule: {
        Args: { p_dispatch_url?: string }
        Returns: Json
      }
      erp_platform_enter_tenant: {
        Args: { p_reason: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_erase_enquiry: {
        Args: { p_id: string; p_reason: string }
        Returns: Json
      }
      erp_platform_flag_security_incident: {
        Args: { p_incident_code: string }
        Returns: number
      }
      erp_platform_generate_invoices: {
        Args: { p_contract_id: string }
        Returns: number
      }
      erp_platform_incident_actions: {
        Args: { p_code?: string }
        Returns: Json
      }
      erp_platform_incident_communication: {
        Args: { p_code?: string }
        Returns: Json
      }
      erp_platform_incident_organisations: {
        Args: { p_incident_code: string }
        Returns: Json
      }
      erp_platform_incidents: { Args: never; Returns: Json }
      erp_platform_invite_admin: {
        Args: { p_display_name: string; p_email: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_invoices: { Args: { p_contract_id: string }; Returns: Json }
      erp_platform_issue_invoice: {
        Args: { p_invoice_id: string }
        Returns: Json
      }
      erp_platform_leave_tenant: {
        Args: { p_tenant_id: string }
        Returns: Json
      }
      erp_platform_maintenance_windows: { Args: never; Returns: Json }
      erp_platform_me: { Args: never; Returns: Json }
      erp_platform_my_tenancies: { Args: never; Returns: Json }
      erp_platform_name_affected_organisations: {
        Args: { p_incident_code: string; p_tenant_codes: string[] }
        Returns: number
      }
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
      erp_platform_plans: { Args: never; Returns: Json }
      erp_platform_policy_decisions: { Args: never; Returns: Json }
      erp_platform_post_incident_update: {
        Args: {
          p_affected?: string
          p_being_done?: string
          p_body?: string
          p_code: string
          p_is_no_change?: boolean
          p_meanwhile?: string
          p_next_update_minutes?: number
          p_not_affected?: string
        }
        Returns: string
      }
      erp_platform_product_decisions: { Args: never; Returns: Json }
      erp_platform_propose_renewals: { Args: never; Returns: number }
      erp_platform_purge_due_tenants: {
        Args: { p_grace_days?: number }
        Returns: Json
      }
      erp_platform_purge_tenant: {
        Args: { p_confirm_code: string; p_reason: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_record_disclosure: {
        Args: {
          p_incident_code: string
          p_note?: string
          p_obligation_code: string
        }
        Returns: undefined
      }
      erp_platform_record_invoice_paid: {
        Args: { p_invoice_id: string; p_payment_reference: string }
        Returns: undefined
      }
      erp_platform_record_restore_drill: {
        Args: {
          p_assertions_failed: number
          p_assertions_passed: number
          p_assertions_run: string[]
          p_commitment_code: string
          p_finished_at: string
          p_note?: string
          p_outcome: string
          p_restored_from: string
          p_restored_to: string
          p_started_at: string
          p_tenant_scope?: string
        }
        Returns: Json
      }
      erp_platform_record_support_action: {
        Args: {
          p_access_id: string
          p_action: string
          p_is_write?: boolean
          p_object_id?: string
          p_object_type?: string
          p_reason: string
        }
        Returns: string
      }
      erp_platform_renew_contract: {
        Args: {
          p_customer_signer: string
          p_platform_signer: string
          p_renewal_id: string
          p_signature_meaning: string
        }
        Returns: string
      }
      erp_platform_resolve_incident: {
        Args: { p_code: string; p_review_url?: string }
        Returns: undefined
      }
      erp_platform_respond_ownership_transfer: {
        Args: { p_accept: boolean; p_note?: string; p_transfer_id: string }
        Returns: Json
      }
      erp_platform_revenue: { Args: never; Returns: Json }
      erp_platform_revoke_staff: {
        Args: { p_id: string; p_reason?: string }
        Returns: Json
      }
      erp_platform_run_check: { Args: { p_code: string }; Returns: Json }
      erp_platform_run_due_jobs: {
        Args: { p_batch_size?: number }
        Returns: Json
      }
      erp_platform_set_index_rate: {
        Args: {
          p_index_code: string
          p_period: string
          p_rate_pct: number
          p_source?: string
        }
        Returns: undefined
      }
      erp_platform_set_staff_role: {
        Args: { p_id: string; p_role: string }
        Returns: Json
      }
      erp_platform_set_tenant_status: {
        Args: { p_reason?: string; p_status: string; p_tenant_id: string }
        Returns: Json
      }
      erp_platform_sign_amendment: {
        Args: {
          p_amendment_id: string
          p_customer_signer: string
          p_platform_signer: string
          p_signature_meaning: string
        }
        Returns: string
      }
      erp_platform_sign_contract: {
        Args: {
          p_contract_id: string
          p_customer_signer: string
          p_platform_signer: string
          p_signature_meaning: string
        }
        Returns: string
      }
      erp_platform_similar_incident_actions: {
        Args: { p_code: string }
        Returns: Json
      }
      erp_platform_staff: { Args: never; Returns: Json }
      erp_platform_support_access: { Args: never; Returns: Json }
      erp_platform_tenant_configuration: { Args: never; Returns: Json }
      erp_platform_tenants: { Args: never; Returns: Json }
      erp_post_count: { Args: { p_task_id: string }; Returns: number }
      erp_post_intercompany_elimination: {
        Args: { p_as_at: string; p_parent_entity_id: string; p_reason: string }
        Returns: string
      }
      erp_posting_classes: { Args: { p_kind?: string }; Returns: Json }
      erp_posting_overrides: { Args: { p_limit?: number }; Returns: Json }
      erp_presets: { Args: never; Returns: Json }
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
      erp_preview_dimensions: { Args: { p_document_id: string }; Returns: Json }
      erp_preview_import: { Args: { p_batch_id: string }; Returns: Json }
      erp_preview_item_code: {
        Args: { p_classification?: Json; p_template_id: string }
        Returns: Json
      }
      erp_price_book: { Args: never; Returns: Json }
      erp_price_document_line: { Args: { p_line_id: string }; Returns: number }
      erp_principals: { Args: never; Returns: Json }
      erp_print_queue_health: { Args: never; Returns: Json }
      erp_print_release_wave: { Args: { p_wave_id: string }; Returns: Json }
      erp_print_routes: { Args: never; Returns: Json }
      erp_printers: { Args: never; Returns: Json }
      erp_promise_date: {
        Args: { p_item_id: string; p_quantity: number; p_site_id: string }
        Returns: string
      }
      erp_promote_change_set: {
        Args: { p_change_set_id: string }
        Returns: Json
      }
      erp_proposals: { Args: { p_status?: string }; Returns: Json }
      erp_propose_allocation_policy: {
        Args: {
          p_change_set_id: string
          p_entity_code: string
          p_site_code: string
          p_value: Json
        }
        Returns: string
      }
      erp_propose_from_interview: {
        Args: { p_session_id: string }
        Returns: Json
      }
      erp_propose_identity_policy: {
        Args: {
          p_change_set_id: string
          p_code: string
          p_count_method: string
          p_device_task_code: string
          p_effective_from: string
          p_identity_level: string
          p_item_class: string
          p_name: string
          p_site_code: string
        }
        Returns: string
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
      erp_quote_margin: { Args: { p_document_id: string }; Returns: Json }
      erp_quote_transition: {
        Args: {
          p_document_id: string
          p_reason?: string
          p_transition_code: string
        }
        Returns: string
      }
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
      erp_raise_drop_ship_order: {
        Args: { p_sales_order_id: string; p_supplier_party_id: string }
        Returns: string
      }
      erp_raise_intercompany_order: {
        Args: { p_sales_order_id: string; p_site_id: string }
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
      erp_reason_codes: { Args: { p_category?: string }; Returns: Json }
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
      erp_reconcile_ambiguous_command: {
        Args: { p_command_id: string; p_evidence: string; p_outcome: string }
        Returns: Json
      }
      erp_reconcile_settlement_statement: {
        Args: { p_statement_id: string }
        Returns: Json
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
      erp_record_device_action: {
        Args: {
          p_captured_at?: string
          p_device_code: string
          p_idempotency_key: string
          p_input_method?: string
          p_keyed_reason?: string
          p_payload?: Json
          p_task_code: string
        }
        Returns: Json
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
      erp_record_parallel_run_figure: {
        Args: {
          p_as_at: string
          p_domain_code: string
          p_legacy_value_minor: number
          p_note?: string
          p_tolerance_minor?: number
        }
        Returns: Json
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
      erp_record_sender_verification: {
        Args: {
          p_dkim: boolean
          p_dmarc: boolean
          p_domain: string
          p_spf: boolean
        }
        Returns: Json
      }
      erp_redistribution_suggestions: {
        Args: { p_days?: number }
        Returns: Json
      }
      erp_refusals: { Args: { p_locale?: string }; Returns: Json }
      erp_refuse_erasure: {
        Args: { p_reason: string; p_request_id: string }
        Returns: Json
      }
      erp_register_device: {
        Args: {
          p_code: string
          p_device_class: string
          p_name: string
          p_serial_number?: string
          p_site_code: string
        }
        Returns: string
      }
      erp_release_area_locations: { Args: never; Returns: Json }
      erp_release_areas: { Args: { p_site_id?: string }; Returns: Json }
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
      erp_release_wave_lines: { Args: { p_wave_id: string }; Returns: Json }
      erp_release_waves: {
        Args: { p_limit?: number; p_release_area_id?: string }
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
      erp_remove_principal: {
        Args: { p_app_user_id: string; p_reason?: string }
        Returns: Json
      }
      erp_remove_quote_line: { Args: { p_line_id: string }; Returns: undefined }
      erp_remove_report_pack_item: {
        Args: { p_pack_code: string; p_report_code: string }
        Returns: undefined
      }
      erp_remove_storage_rule: {
        Args: { p_storage_rule_id: string }
        Returns: string
      }
      erp_render_label: {
        Args: {
          p_document_id?: string
          p_locale?: string
          p_printer_code: string
          p_template_code: string
        }
        Returns: Json
      }
      erp_render_output_template: {
        Args: { p_code: string; p_document_id?: string; p_locale?: string }
        Returns: Json
      }
      erp_reopen_period: {
        Args: { p_fiscal_period_id: string; p_reason: string }
        Returns: number
      }
      erp_replay_message: {
        Args: { p_message_id: number; p_reason: string }
        Returns: number
      }
      erp_report_extract_content: { Args: { p_run_id: string }; Returns: Json }
      erp_report_extracts: { Args: never; Returns: Json }
      erp_report_packs: { Args: never; Returns: Json }
      erp_report_reproducibility: { Args: never; Returns: Json }
      erp_report_runs: { Args: never; Returns: Json }
      erp_report_subscriptions: { Args: never; Returns: Json }
      erp_report_versions: { Args: never; Returns: Json }
      erp_reprint_output: {
        Args: {
          p_printer_code?: string
          p_render_id: string
          p_site_id?: string
          p_workstation?: string
        }
        Returns: Json
      }
      erp_request_erasure: {
        Args: { p_reason: string; p_subject_id: string; p_subject_kind: string }
        Returns: Json
      }
      erp_request_tenant_deletion: {
        Args: { p_confirm_code: string; p_reason: string }
        Returns: Json
      }
      erp_reserve_for_line: {
        Args: { p_document_line_id: string; p_policy_code?: string }
        Returns: string
      }
      erp_resolve_item_supplier: {
        Args: { p_item_id: string; p_site_id?: string }
        Returns: Json
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
      erp_resolve_scan: {
        Args: {
          p_barcode: string
          p_device_code?: string
          p_fields?: Json
          p_key: string
        }
        Returns: Json
      }
      erp_resource_catalog: { Args: { p_locale?: string }; Returns: Json }
      erp_resources: { Args: { p_locale?: string }; Returns: Json }
      erp_retire_account_determination: {
        Args: { p_rule_id: string }
        Returns: Json
      }
      erp_retire_analytics_contract: {
        Args: { p_version: number; p_view_code: string }
        Returns: undefined
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
      erp_revert_cutover: {
        Args: { p_domain_code: string; p_reason: string }
        Returns: Json
      }
      erp_revise_analytics_contract: {
        Args: {
          p_deprecation_notice: string
          p_retire_after: string
          p_view_code: string
        }
        Returns: number
      }
      erp_revise_quote: {
        Args: { p_document_id: string; p_reason?: string }
        Returns: string
      }
      erp_revoke_analytics_credential: {
        Args: { p_credential_id: string; p_reason: string }
        Returns: undefined
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
      erp_route_print: {
        Args: {
          p_render_id: string
          p_site_id?: string
          p_workstation?: string
        }
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
        Args: {
          p_assumptions?: Json
          p_horizon_days?: number
          p_label?: string
          p_scenario_code?: string
          p_site_id: string
        }
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
      erp_scan: {
        Args: {
          p_barcode: string
          p_device_code: string
          p_item_class?: string
          p_symbology: string
          p_task_code: string
        }
        Returns: Json
      }
      erp_scan_rules: { Args: never; Returns: Json }
      erp_scenario_completions: { Args: never; Returns: Json }
      erp_seed_demo: { Args: never; Returns: Json }
      erp_seed_demo_configuration: { Args: never; Returns: Json }
      erp_seed_demo_history: {
        Args: { p_from?: string; p_scale?: number; p_to?: string }
        Returns: Json
      }
      erp_seed_demo_operations: { Args: never; Returns: Json }
      erp_select_carrier: {
        Args: { p_required_by?: string; p_shipment_id: string }
        Returns: Json
      }
      erp_sender_identities: { Args: never; Returns: Json }
      erp_service_notices: { Args: never; Returns: Json }
      erp_session: { Args: never; Returns: Json }
      erp_set_account_dimension_requirements: {
        Args: { p_account_id: string; p_dimension_codes: string }
        Returns: Json
      }
      erp_set_active_tenant: { Args: { p_tenant_id: string }; Returns: Json }
      erp_set_capability: {
        Args: {
          p_code: string
          p_enabled: boolean
          p_reason?: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_set_cost_model: {
        Args: {
          p_basis?: string
          p_currency: string
          p_infrastructure_minor?: number
          p_item_code: string
          p_pass_through_minor?: number
          p_support_minor?: number
        }
        Returns: string
      }
      erp_set_exchange_rate: {
        Args: {
          p_from: string
          p_rate: number
          p_source?: string
          p_to: string
          p_type?: string
          p_valid_from?: string
        }
        Returns: string
      }
      erp_set_incident_subscription: {
        Args: { p_subscribed?: boolean }
        Returns: Json
      }
      erp_set_item_controls: {
        Args: {
          p_has_expiry?: boolean
          p_is_batch_controlled?: boolean
          p_is_serial_controlled?: boolean
          p_item_id: string
          p_min_remaining_shelf_life_days?: number
          p_quarantine_on_receipt?: boolean
          p_shelf_life_days?: number
        }
        Returns: Json
      }
      erp_set_item_posting_class: {
        Args: {
          p_item_id: string
          p_posting_class_id: string
          p_reason?: string
          p_valid_from?: string
        }
        Returns: Json
      }
      erp_set_item_supplier: {
        Args: {
          p_is_approved_for_use?: boolean
          p_is_default?: boolean
          p_item_id: string
          p_lead_time_days?: number
          p_min_order_quantity?: number
          p_party_id: string
          p_preference_rank?: number
          p_reason?: string
          p_site_id?: string
          p_split_pct?: number
          p_supplier_item_code?: string
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
      erp_set_line_stock_identity: {
        Args: {
          p_batch_id?: string
          p_container_id?: string
          p_line_id: string
          p_location_id?: string
        }
        Returns: Json
      }
      erp_set_my_quiet_hours: {
        Args: {
          p_days_of_week: number[]
          p_ends_at: string
          p_override_at_or_above?: string
          p_starts_at: string
          p_timezone: string
        }
        Returns: string
      }
      erp_set_notification_preference: {
        Args: { p_channel_kind: string; p_is_enabled: boolean }
        Returns: undefined
      }
      erp_set_notification_route_status: {
        Args: { p_code: string; p_status: string }
        Returns: undefined
      }
      erp_set_order_behaviour: {
        Args: {
          p_behaviour: string
          p_document_id: string
          p_valid_to?: string
        }
        Returns: undefined
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
      erp_set_quote_line_discount: {
        Args: { p_discount_pct: number; p_line_id: string }
        Returns: undefined
      }
      erp_set_rate: {
        Args: {
          p_amount_minor: number
          p_currency: string
          p_item_code: string
          p_price_book_code: string
          p_term_kind?: string
        }
        Returns: string
      }
      erp_set_reason_code_status: {
        Args: { p_active: boolean; p_category: string; p_code: string }
        Returns: Json
      }
      erp_set_report_subscription_status: {
        Args: { p_status: string; p_subscription_id: string }
        Returns: undefined
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
      erp_set_standard_cost: {
        Args: {
          p_currency?: string
          p_item_id: string
          p_site_id: string
          p_unit_cost_minor: number
        }
        Returns: string
      }
      erp_set_user_roles: {
        Args: {
          p_app_user_id: string
          p_reason?: string
          p_role_codes: string[]
        }
        Returns: Json
      }
      erp_settlement_statement: {
        Args: { p_statement_id: string }
        Returns: Json
      }
      erp_settlement_statements: { Args: { p_limit?: number }; Returns: Json }
      erp_shipments: { Args: { p_limit?: number }; Returns: Json }
      erp_sign_off_forecast: {
        Args: { p_note?: string; p_version_id: string }
        Returns: undefined
      }
      erp_silent_jobs: { Args: never; Returns: Json }
      erp_sites: { Args: never; Returns: Json }
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
      erp_stage_opening_balances: {
        Args: {
          p_as_at: string
          p_code?: string
          p_control_quantity?: number
          p_control_total_minor: number
          p_domain_code: string
          p_rows: Json
        }
        Returns: Json
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
      erp_start_interview: { Args: { p_code?: string }; Returns: Json }
      erp_start_training_scenario: { Args: { p_code: string }; Returns: Json }
      erp_stock_ageing: { Args: never; Returns: Json }
      erp_stock_audit: { Args: { p_site_id?: string }; Returns: Json }
      erp_stock_audit_lines: {
        Args: { p_location_id?: string; p_site_id?: string }
        Returns: Json
      }
      erp_stock_forecast: {
        Args: { p_days?: number; p_site_id?: string }
        Returns: Json
      }
      erp_stock_health: { Args: never; Returns: Json }
      erp_stock_provision: { Args: never; Returns: Json }
      erp_stock_valuation: { Args: never; Returns: Json }
      erp_storage_rules: {
        Args: { p_rule_kind?: string; p_site_id?: string }
        Returns: Json
      }
      erp_submit_change_request: {
        Args: { p_request_id: string }
        Returns: Json
      }
      erp_submit_change_set: {
        Args: { p_change_set_id: string }
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
      erp_submit_quote: { Args: { p_document_id: string }; Returns: string }
      erp_subscribe_to_report: {
        Args: {
          p_app_user_id?: string
          p_at_time?: string
          p_cadence?: string
          p_destination_kind?: string
          p_parameters?: Json
          p_report_code: string
          p_role_code?: string
          p_subscriber_kind?: string
          p_timezone?: string
        }
        Returns: string
      }
      erp_supplier_balances: { Args: never; Returns: Json }
      erp_supplier_qualification: { Args: never; Returns: Json }
      erp_supply_demand: {
        Args: { p_horizon_days?: number; p_item_id: string; p_site_id: string }
        Returns: Json
      }
      erp_support_severities: { Args: never; Returns: Json }
      erp_symbologies: { Args: never; Returns: Json }
      erp_tax_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      erp_tenant_keys: { Args: never; Returns: Json }
      erp_tenant_state: { Args: never; Returns: Json }
      erp_timezones: { Args: never; Returns: Json }
      erp_training_runs: { Args: never; Returns: Json }
      erp_training_scenarios: { Args: never; Returns: Json }
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
      erp_unblock_location: { Args: { p_location_id: string }; Returns: string }
      erp_untranslated: {
        Args: { p_locale?: string }
        Returns: {
          en_value: string
          is_tenant_term: boolean
          key: string
          served_from: string
        }[]
      }
      erp_uoms: { Args: never; Returns: Json }
      erp_update_location: {
        Args: {
          p_capacity_quantity?: number
          p_capacity_uom?: string
          p_count_class?: string
          p_is_pickable?: boolean
          p_location_id: string
          p_location_type?: string
          p_name?: string
          p_parent_location_id?: string
        }
        Returns: string
      }
      erp_update_my_profile: {
        Args: {
          p_display_name?: string
          p_document_locale?: string
          p_family_name?: string
          p_given_name?: string
          p_reporting_locale?: string
          p_timezone?: string
          p_user_locale?: string
        }
        Returns: Json
      }
      erp_upgrade_module_configuration: {
        Args: { p_install_code: string }
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
      erp_upsert_classification_axis: {
        Args: {
          p_code: string
          p_is_mandatory?: boolean
          p_item_classes?: string
          p_name: string
          p_name_key?: string
          p_seq?: number
        }
        Returns: Json
      }
      erp_upsert_classification_value: {
        Args: {
          p_abbreviation: string
          p_axis_id: string
          p_code: string
          p_name: string
          p_name_key?: string
          p_parent_value_id?: string
        }
        Returns: Json
      }
      erp_upsert_code_template: {
        Args: {
          p_casing?: string
          p_code: string
          p_entity_id?: string
          p_item_classes?: string
          p_name: string
          p_segments: Json
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
      erp_upsert_dimension: {
        Args: {
          p_code: string
          p_derivation?: Json
          p_is_mandatory_default?: boolean
          p_name: string
          p_status?: string
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
          p_scope?: Json
          p_status?: string
        }
        Returns: Json
      }
      erp_upsert_dimension_value: {
        Args: {
          p_code: string
          p_dimension_code: string
          p_name: string
          p_parent_code?: string
          p_status?: string
          p_valid_from?: string
          p_valid_to?: string
        }
        Returns: Json
      }
      erp_upsert_forecast_event: {
        Args: {
          p_code: string
          p_ends_on: string
          p_entity_id?: string
          p_item_id?: string
          p_multiplier: number
          p_name: string
          p_reason: string
          p_site_id?: string
          p_starts_on: string
          p_status?: string
        }
        Returns: string
      }
      erp_upsert_job: {
        Args: {
          p_at_time?: string
          p_code: string
          p_day_of_month?: number
          p_days_of_week?: string
          p_handler_code: string
          p_interval_seconds?: number
          p_is_enabled?: boolean
          p_max_silence_seconds?: number
          p_name: string
          p_parameters?: Json
          p_schedule_kind: string
          p_timeout_seconds?: number
          p_timezone?: string
        }
        Returns: Json
      }
      erp_upsert_notification_channel: {
        Args: {
          p_code: string
          p_credential_ref?: string
          p_is_enabled?: boolean
          p_kind: string
          p_name: string
          p_settings?: Json
        }
        Returns: string
      }
      erp_upsert_notification_route: {
        Args: {
          p_app_user_id?: string
          p_audience_kind?: string
          p_channel_kind?: string
          p_code: string
          p_department_code?: string
          p_digest_minutes?: number
          p_escalate_after_minutes?: number
          p_escalate_to_role_code?: string
          p_event_pattern: string
          p_is_mandatory?: boolean
          p_name: string
          p_role_code?: string
          p_severity?: string
          p_template_code?: string
        }
        Returns: string
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
      erp_upsert_price_item: {
        Args: {
          p_band_from?: number
          p_band_to?: number
          p_capability_code?: string
          p_code: string
          p_description?: string
          p_entitlement_code?: string
          p_kind: string
          p_legislation_pack_code?: string
          p_name: string
          p_plan_code?: string
          p_support_severity_code?: string
        }
        Returns: string
      }
      erp_upsert_print_route: {
        Args: {
          p_app_user_id?: string
          p_code: string
          p_output_kind: string
          p_printer_code: string
          p_priority?: number
          p_site_id?: string
          p_template_code?: string
          p_workstation?: string
        }
        Returns: string
      }
      erp_upsert_printer: {
        Args: {
          p_code: string
          p_default_stock?: string
          p_dots_per_inch?: number
          p_language?: string
          p_name: string
          p_physical_location?: string
          p_printer_type: string
          p_queue_address?: string
          p_site_id: string
        }
        Returns: string
      }
      erp_upsert_reason_code: {
        Args: {
          p_category: string
          p_code: string
          p_name: string
          p_requires_approval?: boolean
          p_requires_note?: boolean
          p_seq?: number
        }
        Returns: Json
      }
      erp_upsert_release_area: {
        Args: {
          p_ageing_hours?: number
          p_channel_code?: string
          p_code: string
          p_gate_printing?: boolean
          p_item_classes?: string
          p_location_id?: string
          p_max_quantity?: number
          p_min_quantity?: number
          p_name: string
          p_order_type_code?: string
          p_replenishment_mode?: string
          p_site_id: string
        }
        Returns: Json
      }
      erp_upsert_report_pack: {
        Args: { p_code: string; p_description?: string; p_name: string }
        Returns: string
      }
      erp_upsert_scan_rule: {
        Args: {
          p_accepted_symbologies: string
          p_item_class?: string
          p_mandatory_identifiers?: string
          p_task_code: string
          p_when_absent?: string
        }
        Returns: string
      }
      erp_upsert_sender_identity: {
        Args: {
          p_category?: string
          p_domain: string
          p_from_local_part?: string
          p_reply_to?: string
        }
        Returns: string
      }
      erp_upsert_training_scenario: {
        Args: {
          p_code: string
          p_completion_code: string
          p_permission_code: string
          p_starting_state: string
          p_task: string
          p_title: string
        }
        Returns: Json
      }
      erp_validate_import: { Args: { p_batch_id: string }; Returns: Json }
      erp_vocabularies: { Args: never; Returns: Json }
      erp_warehouse_tasks: {
        Args: { p_kind?: string; p_limit?: number; p_site_id?: string }
        Returns: Json
      }
      erp_wave_print_readiness: { Args: { p_wave_id: string }; Returns: Json }
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
          p_owner_party_id?: string
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
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
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
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
