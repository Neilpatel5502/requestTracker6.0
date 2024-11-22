package RT::Action::AddTicketSummary;

use RT;
use RT::Config;
use strict;
use warnings;
use base qw(RT::Action);



use HTTP::Request::Common;
use LWP::UserAgent;
use JSON;

sub Prepare {
    my $self = shift;

    # Nothing to do in Prepare
    return 1;
}


sub Commit {
	my $self = shift;
	RT->LoadConfig;
	my $config = RT->Config;

	my $api_key = $config->Get('OpenAI_ApiKey');
	my $url = $config->Get('OpenAI_ApiUrl');

	my $ticket_id = $self->TicketObj->id;
	my $ticket_transactions = $self->TicketObj->Transactions;
	my $conversation_input = '';  # Store full conversation history
	my $summary_prompt = $config->Get('TicketSummary');
	my $GeneralAIModel = $config->Get('GeneralAIModel')->{modelDetails};

	my $modelName = $GeneralAIModel->{modelName};
    	my $temperature = $GeneralAIModel->{temperature};
    	my $maxToken = $GeneralAIModel->{maxToken};
    	my $stream = $GeneralAIModel->{stream};
	
	my %seen_messages;  # Hash to track and ignore duplicate messages

	# Iterate over each transaction in the ticket history
	while (my $transaction = $ticket_transactions->Next) {
    		my $content = $transaction->Content;
    		my $type = $transaction->Type;

    		# Skip empty or irrelevant transactions
    		next if !$content || $content =~ /This transaction appears to have no content/i;

    		# Ignore automatic acknowledgments
    		if ($content =~ /This message has been automatically generated/i
        		|| $content =~ /There is no need to reply/i
        		|| $content =~ /Your ticket has been assigned an ID/i) {
        		next;
    		}

    		# Remove quoted text and metadata from email replies (such as "On Fri Oct 11...")
    		$content =~ s/^On .* wrote:\s*//gm;  # Remove "On [date] wrote:" lines
    		$content =~ s/^>.*//gm;              # Remove lines starting with ">"

    		# Skip duplicate content (already processed earlier in the conversation)
    		if ($seen_messages{$content}) {
        		next;
    		}
    		$seen_messages{$content} = 1;  # Mark this content as seen to avoid future duplicates

    		# Skip empty content after cleaning
    		next if $content =~ /^\s*$/;

    		# Classify the actor based on transaction type
    		my $role;
    		if ($type eq 'Correspond') {
        		$role = IsOutsideActor($self, $transaction) ? 'User' : 'Staff';
    		} elsif ($type eq 'Comment') {
        		$role = 'Staff';
    		} else {
        		next;  # Skip if the transaction type is neither correspond nor comment
    		}

    		# Append the conversation with the role and the cleaned content
    		$conversation_input .= "$role: $content\n";
	}


	RT::Logger->info("From Extension: Ticket conversation history: " . $conversation_input);

	unless ($conversation_input) {
    		$RT::Logger->info("No valid content to summarize for ticket #$ticket_id.");
    		return 1;
	}

	# Create an HTTP request to the OpenAI API for summarization
	my $ua = LWP::UserAgent->new;
	my $request = HTTP::Request->new(POST => $url);
	$request->header('Content-Type' => 'application/json');
	$request->header('Authorization' => "Bearer $api_key");

	# Structure the payload for the OpenAI request
	my $data = {
    		"model" => $modelName,
    		"messages" => [{
        		"role" => "system",
        		"content" => $summary_prompt
    		}, {
        		"role" => "user",
        		"content" => $conversation_input
    		}],
    		"max_tokens" => $maxToken,  
		"temperature" => $temperature 
	};

	# Send the request to the OpenAI API
	$request->content(encode_json($data));
	my $response = $ua->request($request);

	# Process the response from the OpenAI API
	if ($response->is_success) {
    		my $result = decode_json($response->decoded_content);
    		
		# Extract and log the generated summary
    		if (defined($result->{'choices'}[0]{'message'}{'content'})) {
        		my $summary = $result->{'choices'}[0]{'message'}{'content'};
        		RT::Logger->info("Generated summary for ticket #$ticket_id: $summary");
        		# Save the summary as a custom field in the ticket
        		$self->TicketObj->AddCustomFieldValue(
            			Field => 'Ticket Summary',
            			Value => $summary
        		);
    		} else {
        		$RT::Logger->error("Unexpected response structure from OpenAI API for ticket #$ticket_id: " . $response->decoded_content);
    		}
	} else {
    		# Log error if summarization request fails
    		$RT::Logger->error("Failed to perform summarization for ticket #$ticket_id: " . $response->status_line);
	}


	# Helper subroutine to determine if the actor is an outside (User) or inside (Staff) actor
	sub IsOutsideActor {
    		my $self = shift;
    		my $txn = shift || return 0;  # default to not an outside actor if transaction is not provided
    		my $actor = $txn->CreatorObj->PrincipalObj;
    		# owner is always treated as inside actor (Staff)
    		return 0 if $actor->id == $self->TicketObj->Owner;
    		if ( RT->Config->Get('ServiceAgreements')->{'AssumeOutsideActor'} ) {
        		# All non-admincc users are outside actors (Users)
        		return 0 if $self->TicketObj->AdminCc->HasMemberRecursively( $actor )
                 		or $self->TicketObj->QueueObj->AdminCc->HasMemberRecursively( $actor );
        		return 1;
    		} else {
        		# Only requestors are outside actors (Users)
        		return 1 if $self->TicketObj->Requestors->HasMemberRecursively( $actor );
        		return 0;
    		}
	}
}

RT::Base->_ImportOverlays();

1;